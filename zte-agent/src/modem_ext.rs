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
    // Read fresh, not through the cache: the merge must start from the modem's state now.
    let current = match ubus::call("zwrt_data", "get_wwaniface", Some(r#"{"cid":1}"#)) {
        Ok(current) => current,
        Err(e) => return (503, json!({"ok": false, "error": e})),
    };
    let merged = match merge_data_update(&current, &parsed) {
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

/// `set_wwaniface` replaces the whole data-call record. A request names only what it changes
/// and the rest comes from the modem's current record, so a client's stale copy cannot, for
/// example, switch mobile data off while changing roaming.
fn merge_data_update(current: &Value, update: &Value) -> Result<Value, &'static str> {
    let update = update.as_object().ok_or("invalid_data_update")?;
    let flag = |value: &Value| -> Option<u8> {
        match value {
            Value::Number(n) => n.as_u64().filter(|n| *n <= 1).map(|n| n as u8),
            Value::String(s) => s.parse::<u8>().ok().filter(|n| *n <= 1),
            _ => None,
        }
    };
    let mut merged = serde_json::Map::new();
    merged.insert("cid".into(), json!(1));
    for field in ["connect_mode", "roam_enable", "enable"] {
        let value = match update.get(field) {
            Some(value) => flag(value).ok_or("invalid_data_update")?,
            None => current.get(field).and_then(flag).ok_or("modem_data_unavailable")?,
        };
        merged.insert(field.into(), json!(value));
    }
    for (key, value) in update {
        if !["cid", "connect_mode", "roam_enable", "enable"].contains(&key.as_str()) {
            merged.insert(key.clone(), value.clone());
        }
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
    use super::merge_data_update;
    use serde_json::json;

    fn current(enable: u8) -> serde_json::Value {
        json!({"cid": 1, "connect_mode": 1, "roam_enable": 1, "enable": enable, "connect_status": "ipv4_connected"})
    }

    #[test]
    fn changing_roaming_keeps_the_current_data_switch() {
        // 2026-10-22: roaming off sent {"enable":0} from a stale copy and disconnected data.
        let merged = merge_data_update(&current(1), &json!({"roam_enable": 0})).unwrap();
        assert_eq!(merged, json!({"cid": 1, "connect_mode": 1, "roam_enable": 0, "enable": 1}));
        let merged = merge_data_update(&current(0), &json!({"roam_enable": 0})).unwrap();
        assert_eq!(merged["enable"], 0);
    }

    #[test]
    fn named_fields_win_and_extra_fields_pass_through() {
        let merged = merge_data_update(&current(1), &json!({"enable": 0, "connect_status": "disconnected"})).unwrap();
        assert_eq!(merged, json!({"cid": 1, "connect_mode": 1, "roam_enable": 1, "enable": 0, "connect_status": "disconnected"}));
        let merged = merge_data_update(&current(0), &json!({"enable": "1", "connect_mode": 0})).unwrap();
        assert_eq!((merged["enable"].clone(), merged["connect_mode"].clone()), (json!(1), json!(0)));
    }

    #[test]
    fn invalid_values_or_an_unknown_current_state_are_refused() {
        assert_eq!(merge_data_update(&current(1), &json!({"enable": 2})), Err("invalid_data_update"));
        assert_eq!(merge_data_update(&current(1), &json!({"enable": true})), Err("invalid_data_update"));
        assert_eq!(merge_data_update(&current(1), &json!([1])), Err("invalid_data_update"));
        assert_eq!(merge_data_update(&json!({"cid": 1}), &json!({"roam_enable": 0})), Err("modem_data_unavailable"));
    }
}
