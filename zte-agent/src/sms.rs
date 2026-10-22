use std::collections::BTreeMap;
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::handlers::AppState;
use crate::ubus;

const SMS_DB_PATH: &str = "/etc_rw/ztembb/ztesms/sms_db/sms.db";

pub(crate) fn query_database(sql: &str, max_bytes: u64) -> Result<String, &'static str> {
    let mut child = Command::new("/usr/bin/sqlite3")
        .args([
            "-cmd",
            ".timeout 2000",
            "-readonly",
            "-separator",
            "\t",
            SMS_DB_PATH,
            sql,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "sms_database_unavailable")?;
    let stdout = child.stdout.take().ok_or("sms_database_pipe_failed")?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.take(max_bytes + 1).read_to_end(&mut bytes).map(|_| bytes)
    });
    let deadline = Instant::now() + Duration::from_secs(3);
    let result = loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                break if status.success() {
                    Ok(())
                } else {
                    Err("sms_database_query_failed")
                }
            }
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            Ok(None) => break Err("sms_database_timeout"),
            Err(_) => break Err("sms_database_wait_failed"),
        }
    };
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    let bytes = reader
        .join()
        .map_err(|_| "sms_database_reader_failed")?
        .map_err(|_| "sms_database_read_failed")?;
    result?;
    if bytes.len() as u64 > max_bytes {
        return Err("sms_database_response_too_large");
    }
    String::from_utf8(bytes).map_err(|_| "invalid_sms_metadata")
}
pub(crate) fn decode_database_text(value: &str) -> Result<String, &'static str> {
    if value.len() % 2 != 0 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("invalid_sms_encoding");
    }
    let bytes = value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            u8::from_str_radix(std::str::from_utf8(pair).expect("ASCII hex"), 16)
                .expect("validated hex")
        })
        .collect();
    let raw = String::from_utf8(bytes).map_err(|_| "invalid_sms_encoding")?;
    if !raw.is_empty() && raw.len() % 4 == 0 && raw.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        let units: Vec<_> = raw
            .as_bytes()
            .chunks_exact(4)
            .map(|unit| {
                u16::from_str_radix(std::str::from_utf8(unit).expect("ASCII hex"), 16)
                    .expect("validated hex")
            })
            .collect();
        String::from_utf16(&units).map_err(|_| "invalid_sms_encoding")
    } else {
        Ok(raw)
    }
}


pub fn sms_list(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    let result = ubus::call("zwrt_wms", "zte_libwms_get_sms_data", Some(&parsed.to_string()))
        .and_then(|mut data| {
            let ids = message_ids(&data).map_err(str::to_string)?;
            if !ids.is_empty() {
                // The firmware can encrypt both fields in its ubus reply. Keep
                // its pagination/metadata, but use the same stored text as APNs.
                let ids = ids.iter().map(u64::to_string).collect::<Vec<_>>().join(",");
                let rows = query_database(
                    &format!("SELECT id,hex(Number),hex(Content) FROM sms WHERE id IN ({ids});"),
                    32 * 1048576,
                ).map_err(str::to_string)?;
                restore_message_text(&mut data, &rows).map_err(str::to_string)?;
            }
            state.sms_history.decorate(state, &mut data)?;
            Ok(data)
        });
    match result {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

fn message_id(message: &Value) -> Result<u64, &'static str> {
    message.get("id").and_then(|id| id.as_u64().or_else(|| id.as_str()?.parse().ok()))
        .filter(|id| *id > 0).ok_or("invalid_sms_message_id")
}

fn message_ids(data: &Value) -> Result<Vec<u64>, &'static str> {
    data.get("messages").and_then(Value::as_array).ok_or("invalid_sms_list")?
        .iter().map(message_id).collect()
}

fn restore_message_text(data: &mut Value, rows: &str) -> Result<(), &'static str> {
    let mut stored = BTreeMap::new();
    for row in rows.lines() {
        let fields: Vec<_> = row.split('\t').collect();
        if fields.len() != 3 { return Err("invalid_sms_text_row"); }
        let id: u64 = fields[0].parse().map_err(|_| "invalid_sms_text_row")?;
        let sender = decode_database_text(fields[1])?;
        let content = decode_database_text(fields[2])?;
        if stored.insert(id, (sender, content)).is_some() { return Err("duplicate_sms_text_row"); }
    }
    let messages = data.get_mut("messages").and_then(Value::as_array_mut).ok_or("invalid_sms_list")?;
    for message in messages {
        let (sender, content) = stored.get(&message_id(message)?).ok_or("sms_message_disappeared")?;
        message["number"] = json!(sender);
        // Preserve the established UTF-16BE hex response used by both apps.
        let encoded = content.encode_utf16().map(|unit| format!("{unit:04X}")).collect::<String>();
        message["content"] = json!(encoded);
    }
    Ok(())
}

pub fn sms_capacity(_state: &AppState) -> (u16, Value) {
    match ubus::call("zwrt_wms", "zwrt_wms_get_wms_capacity", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn sms_send(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    match state.sms_history.send(state, &parsed, || ubus::call("zwrt_wms", "zte_libwms_send_sms", Some(&parsed.to_string()))) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

/// Delete one or more SMS by id.
///
/// Body shape (legacy ZTE format): `{"id": "3681;3682;"}` — semicolon-joined ids with trailing `;`.
///
/// Firmware bug: `zwrt_wms_delete_sms` works for NV-stored messages but silently returns
/// `{"result": 3}` without deleting SIM-stored rows. The daemon's listing reads from
/// `/etc_rw/ztembb/ztesms/sms_db/sms.db`, so we fall back to a direct SQLite DELETE for any
/// id that survived the ubus call.
pub fn sms_delete(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };

    let ids = match parse_ids(parsed.get("id")) {
        Ok(v) if !v.is_empty() => v,
        Ok(_) => return (400, json!({"ok": false, "error": "no ids in 'id' field"})),
        Err(e) => return (400, json!({"ok": false, "error": e})),
    };

    let ubus_result = ubus::call("zwrt_wms", "zwrt_wms_delete_sms", Some(&parsed.to_string()));

    let survivors = match db_filter_existing(&ids) {
        Ok(v) => v,
        Err(e) => {
            return match ubus_result {
                Ok(data) => (200, json!({"ok": true, "data": data, "warning": format!("db check skipped: {e}")})),
                Err(ubus_err) => (503, json!({"ok": false, "error": format!("ubus: {ubus_err}; db: {e}")})),
            };
        }
    };

    if survivors.is_empty() {
        return (
            200,
            json!({"ok": true, "data": ubus_result.unwrap_or(Value::Null), "deleted_via": "ubus"}),
        );
    }

    match db_delete_ids(&survivors) {
        Ok(()) => (
            200,
            json!({"ok": true, "deleted_via": "sqlite", "ids": survivors}),
        ),
        Err(e) => (503, json!({"ok": false, "error": format!("sqlite delete failed: {e}")})),
    }
}

/// Parse the legacy ZTE id format (semicolon-joined with trailing `;`).
fn parse_ids(field: Option<&Value>) -> Result<Vec<i64>, String> {
    let raw = field.ok_or_else(|| "missing 'id' field".to_string())?;
    let s = raw.as_str().ok_or_else(|| "'id' must be a string".to_string())?;
    let mut out = Vec::new();
    for part in s.split(';') {
        let p = part.trim();
        if p.is_empty() {
            continue;
        }
        let n: i64 = p
            .parse()
            .map_err(|_| format!("invalid id '{p}' (must be integer)"))?;
        out.push(n);
    }
    Ok(out)
}

/// Return the subset of `ids` still present in the WMS sms table.
fn db_filter_existing(ids: &[i64]) -> Result<Vec<i64>, String> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let in_clause = ids
        .iter()
        .map(|n| n.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!("SELECT id FROM sms WHERE id IN ({in_clause});");
    let output = Command::new("/usr/bin/sqlite3")
        .args(["-cmd", ".timeout 2000", "-readonly", SMS_DB_PATH, &sql])
        .output()
        .map_err(|e| format!("spawn sqlite3: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    let mut out = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let l = line.trim();
        if l.is_empty() {
            continue;
        }
        if let Ok(n) = l.parse::<i64>() {
            out.push(n);
        }
    }
    Ok(out)
}

/// Direct DELETE bypassing the broken ubus path.
fn db_delete_ids(ids: &[i64]) -> Result<(), String> {
    if ids.is_empty() {
        return Ok(());
    }
    let in_clause = ids
        .iter()
        .map(|n| n.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!("DELETE FROM sms WHERE id IN ({in_clause});");
    let output = Command::new("/usr/bin/sqlite3")
        .args(["-cmd", ".timeout 2000", SMS_DB_PATH, &sql])
        .output()
        .map_err(|e| format!("spawn sqlite3: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(())
}

pub fn sms_mark_read(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    match ubus::call("zwrt_wms", "zwrt_wms_modify_tag", Some(&parsed.to_string())) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(text: &str) -> String {
        text.as_bytes().iter().map(|byte| format!("{byte:02X}")).collect()
    }

    #[test]
    fn stored_text_replaces_opaque_ubus_fields_and_preserves_message_metadata() {
        let mut data = json!({"messages":[
            {"id":7,"number":"opaque sender","content":"opaque body","tag":"0","date":"26,10,22,12,00,00,+8","mem_store":"nv"},
            {"id":8,"number":"opaque sender","content":"opaque body","tag":"2","draft_group_id":"group","mem_store":"sim"}
        ]});
        let original = data.clone();
        let text = "Welkom! cadeau: €5 en 中文 🐼\nTweede regel\tend";
        let encoded = text.encode_utf16().map(|unit| format!("{unit:04X}")).collect::<String>();
        let rows = format!("7\t{}\t{}\n8\t{}\t{}\n",hex("PROVIDER"),hex(&encoded),hex("+31123456789"),hex("Plain GSM text"));
        restore_message_text(&mut data,&rows).unwrap();
        assert_eq!(message_ids(&data).unwrap(),vec![7,8]);
        assert_eq!(data["messages"][0]["number"],"PROVIDER");
        assert_eq!(data["messages"][0]["content"],encoded);
        assert_eq!(decode_database_text(&hex(data["messages"][1]["content"].as_str().unwrap())).unwrap(),"Plain GSM text");
        for index in 0..2 {
            for key in ["id","tag","date","mem_store","draft_group_id"] {
                assert_eq!(data["messages"][index][key],original["messages"][index][key]);
            }
        }
    }

    #[test]
    fn empty_drafts_and_empty_inboxes_remain_readable() {
        let mut data=json!({"messages":[{"id":1,"number":"opaque","content":"opaque","tag":"4"}]});
        restore_message_text(&mut data,"1\t\t\n").unwrap();
        assert_eq!(data["messages"][0]["number"],"");
        assert_eq!(data["messages"][0]["content"],"");
        assert!(message_ids(&json!({"messages":[]})).unwrap().is_empty());
    }

    #[test]
    fn missing_or_invalid_stored_text_fails_the_read_instead_of_returning_opaque_data() {
        let data=json!({"messages":[{"id":1,"content":"opaque"}]});
        for rows in ["","1\tFF\t00\n","1\t50524F5649444552\t44383030\n","1\textra\tfields\there\n"] {
            assert!(restore_message_text(&mut data.clone(),rows).is_err());
        }
        for id in [json!(0),json!(-1),json!("1 OR 1=1"),Value::Null] {
            assert!(message_ids(&json!({"messages":[{"id":id}]})).is_err());
        }
        assert!(message_ids(&json!({})).is_err());
    }
}
