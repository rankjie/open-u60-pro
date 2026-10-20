use serde_json::{json, Value};

use crate::handlers::AppState;
use crate::ubus;

pub fn usb_status(_state: &AppState) -> (u16, Value) {
    let mut data = match ubus::call("zwrt_bsp.usb", "list", Some("{}")) {
        Ok(Value::Object(data)) => data,
        _ => return (503, json!({"ok":false,"error":"usb_status_unavailable"})),
    };
    let powerbank = match ubus::call("zwrt_bsp.powerbank", "get", Some(r#"{"property":"state"}"#)) {
        Ok(value) if matches!(value["state"].as_i64(), Some(0 | 1)) => value["state"].clone(),
        _ => {
            return (
                503,
                json!({"ok":false,"error":"powerbank_status_unavailable"}),
            )
        }
    };
    data.insert("powerbank_state".into(), powerbank);
    (200, json!({"ok":true,"data":data}))
}

pub fn usb_mode_set(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    match ubus::call("zwrt_bsp.usb", "set", Some(&parsed.to_string())) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn usb_powerbank_set(state: &AppState, body: &[u8]) -> (u16, Value) {
    let result = set_powerbank(
        body,
        |requested| {
            ubus::call(
                "zwrt_bsp.powerbank",
                "set",
                Some(&json!({"state":requested}).to_string()),
            )
        },
        || ubus::call("zwrt_bsp.powerbank", "get", Some(r#"{"property":"state"}"#)),
        || std::thread::sleep(std::time::Duration::from_millis(100)),
    );
    // The charger view changes with powerbank mode; make the next read fresh
    // even if BSP_POWERBANK_EVENT lags.
    state.cache.invalidate(crate::cache::CHARGER);
    result
}

fn set_powerbank(
    body: &[u8],
    mut set: impl FnMut(i64) -> Result<Value, String>,
    mut get: impl FnMut() -> Result<Value, String>,
    mut wait: impl FnMut(),
) -> (u16, Value) {
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Input {
        state: i64,
    }
    let requested = match serde_json::from_slice::<Input>(body) {
        Ok(input) if matches!(input.state, 0 | 1) => input.state,
        _ => return (400, json!({"ok":false,"error":"state must be 0 or 1"})),
    };
    if set(requested).is_err() {
        return (503, json!({"ok":false,"error":"powerbank_set_failed"}));
    }
    // The vendor set acknowledgement can precede the Type-C role transition.
    // Confirm the hardware state before the app displays a successful switch.
    for attempt in 0..10 {
        match get() {
            Ok(value) => match value["state"].as_i64() {
                Some(actual) if actual == requested => {
                    return (200, json!({"ok":true,"data":{"state":actual}}))
                }
                Some(0 | 1) => {}
                _ => {
                    return (
                        503,
                        json!({"ok":false,"error":"invalid_powerbank_readback"}),
                    )
                }
            },
            Err(_) => return (503, json!({"ok":false,"error":"powerbank_readback_failed"})),
        }
        if attempt < 9 {
            wait();
        }
    }
    (
        503,
        json!({"ok":false,"error":"powerbank_state_not_changed"}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn charging_switch_confirms_both_directions() {
        for target in [0, 1] {
            let mut actual = 1 - target;
            let mut reads = 0;
            let (status, response) = set_powerbank(
                &serde_json::to_vec(&json!({"state":target})).unwrap(),
                |state| {
                    assert_eq!(state, target);
                    Ok(json!({"result":0}))
                },
                || {
                    reads += 1;
                    if reads == 3 {
                        actual = target;
                    }
                    Ok(json!({"state":actual}))
                },
                || {},
            );
            assert_eq!(status, 200);
            assert_eq!(response["data"]["state"], target);
            assert_eq!(reads, 3);
        }
    }
    #[test]
    fn acknowledgement_without_hardware_change_is_an_error() {
        let mut reads = 0;
        let (status, response) = set_powerbank(
            br#"{"state":0}"#,
            |_| Ok(json!({"result":0})),
            || {
                reads += 1;
                Ok(json!({"state":1}))
            },
            || {},
        );
        assert_eq!(status, 503);
        assert_eq!(response["error"], "powerbank_state_not_changed");
        assert_eq!(reads, 10);
    }
    #[test]
    fn invalid_state_never_reaches_the_hardware() {
        for body in [
            r#"{"state":-1}"#,
            r#"{"state":2}"#,
            r#"{"state":true}"#,
            "{}",
        ] {
            let (status, _) = set_powerbank(
                body.as_bytes(),
                |_| panic!("invalid state submitted"),
                || panic!("unexpected read"),
                || {},
            );
            assert_eq!(status, 400);
        }
    }
    #[test]
    fn readback_failure_is_not_reported_as_success() {
        let (status, response) = set_powerbank(
            br#"{"state":0}"#,
            |_| Ok(json!({})),
            || Err("unavailable".into()),
            || {},
        );
        assert_eq!(status, 503);
        assert_eq!(response["error"], "powerbank_readback_failed");
    }
}
