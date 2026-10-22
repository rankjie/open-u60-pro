use serde_json::{json, Value};

use crate::cache;
use crate::handlers::AppState;
use crate::ubus;

pub fn modem_data_get(state: &AppState) -> (u16, Value) {
    match wwan(state) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

/// `zwrt_data get_wwaniface` for the data call, through the shared cache.
pub(crate) fn wwan(state: &AppState) -> Result<Value, String> {
    let fetch = || ubus::call("zwrt_data", "get_wwaniface", Some(r#"{"cid":1}"#));
    state.cache.get_or_fetch(cache::MODEM_DATA, cache::MODEM_DATA_TTL, fetch)
}

/// The data daemon applies mode changes asynchronously, so after a local
/// write the modem/data entry is dropped and reads stay near-fresh for the
/// settle window (the apps run 2 s confirmation polls against it).
fn settle_modem_data(state: &AppState) {
    state
        .cache
        .invalidate_with_settle(cache::MODEM_DATA, cache::SETTLE_WINDOW);
}

/// A user-initiated modem change: the no-service policy and the connectivity
/// watchdog hold off for 2 min.
pub(crate) fn note_user_modem_change(state: &AppState) {
    let now = std::time::Instant::now();
    state.oos_policy.set_user_activity(now);
    state.conn_watchdog.set_user_activity(now);
}

/// POST /api/modem/online from the app: AT+CFUN=1 plus the user-activity
/// bookkeeping (the policies' own effects send AT+CFUN=1 directly and never
/// come through here).
pub fn modem_online_user(state: &AppState) -> (u16, Value) {
    note_user_modem_change(state);
    state.oos_policy.user_mode(true);
    crate::handlers::modem_online(state)
}

pub fn modem_data_set(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    let merged = match data_update(&parsed) {
        Ok(merged) => merged,
        Err(code) => return (400, json!({"ok": false, "error": code})),
    };
    note_user_modem_change(state);
    let result = ubus::call("zwrt_data", "set_wwaniface", Some(&merged.to_string()));
    settle_modem_data(state);
    match result {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

/// `set_wwaniface` commits only the fields it is given, so a request carries exactly what the
/// user changed. Nothing is filled in from the modem's record: its `enable` reads 0 after every
/// boot while auto-connect keeps data up, and writing that back disconnects data.
fn data_update(update: &Value) -> Result<Value, &'static str> {
    let update = update.as_object().ok_or("invalid_data_update")?;
    let mut merged = serde_json::Map::new();
    merged.insert("cid".into(), json!(1));
    for (key, value) in update {
        let value = match key.as_str() {
            "cid" => continue,
            "connect_mode" | "roam_enable" | "enable" => {
                let flag = match value {
                    Value::Number(n) => n.as_u64(),
                    Value::String(s) => s.parse::<u64>().ok(),
                    _ => None,
                };
                json!(flag.filter(|n| *n <= 1).ok_or("invalid_data_update")?)
            }
            _ => value.clone(),
        };
        merged.insert(key.clone(), value);
    }
    Ok(Value::Object(merged))
}

pub fn modem_airplane(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    note_user_modem_change(state);
    // Use AT+CFUN=1 for ONLINE (ubus nwinfo_set_mode ONLINE is broken for LPM→ONLINE recovery)
    if parsed["operate_mode"].as_str() == Some("ONLINE") {
        // modem_online settles the modem/data entry itself.
        return modem_online_user(state);
    }
    let result = ubus::call(
        "zte_nwinfo_api",
        "nwinfo_set_mode",
        Some(&parsed.to_string()),
    );
    settle_modem_data(state);
    match result {
        Ok(data) => {
            // The user parked the modem (LPM/OFFLINE): the no-service policy
            // stands down until the user goes ONLINE again.
            state.oos_policy.user_mode(false);
            (200, json!({"ok": true, "data": data}))
        }
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn modem_network_mode_set(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    note_user_modem_change(state);
    let result = ubus::call(
        "zte_nwinfo_api",
        "nwinfo_set_netselect",
        Some(&parsed.to_string()),
    );
    settle_modem_data(state);
    match result {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn modem_scan(_state: &AppState) -> (u16, Value) {
    match ubus::call("zte_nwinfo_api", "nwinfo_manual_scan", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn modem_scan_status(_state: &AppState) -> (u16, Value) {
    match ubus::call("zte_nwinfo_api", "nwinfo_m_netselect_status", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn modem_scan_results(_state: &AppState) -> (u16, Value) {
    match ubus::call("zte_nwinfo_api", "nwinfo_m_netselect_contents", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn modem_register(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    match ubus::call("zte_nwinfo_api", "nwinfo_manual_register", Some(&parsed.to_string())) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn modem_register_result(_state: &AppState) -> (u16, Value) {
    match ubus::call("zte_nwinfo_api", "nwinfo_m_netselect_result", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}


#[cfg(test)]
mod data_update_tests {
    use super::data_update;
    use serde_json::json;

    #[test]
    fn changing_roaming_never_writes_the_data_switch() {
        // After a boot the modem reports "enable":0 while auto-connect keeps data up; copying
        // that value into a roaming change disconnects data (2026-10-22, twice).
        let merged = data_update(&json!({"roam_enable": 0})).unwrap();
        assert_eq!(merged, json!({"cid": 1, "roam_enable": 0}));
        let merged = data_update(&json!({"connect_mode": "0"})).unwrap();
        assert_eq!(merged, json!({"cid": 1, "connect_mode": 0}));
    }

    #[test]
    fn named_fields_are_validated_and_extra_fields_pass_through() {
        let merged = data_update(&json!({"cid": 3, "enable": 0, "connect_status": "disconnected"})).unwrap();
        assert_eq!(merged, json!({"cid": 1, "enable": 0, "connect_status": "disconnected"}));
        let merged = data_update(&json!({"enable": "1", "connect_mode": 0})).unwrap();
        assert_eq!((merged["enable"].clone(), merged["connect_mode"].clone()), (json!(1), json!(0)));
    }

    #[test]
    fn invalid_values_are_refused() {
        assert_eq!(data_update(&json!({"enable": 2})), Err("invalid_data_update"));
        assert_eq!(data_update(&json!({"enable": true})), Err("invalid_data_update"));
        assert_eq!(data_update(&json!([1])), Err("invalid_data_update"));
    }
}
