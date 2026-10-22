use crate::sms::{decode_database_text as decode, query_database as query};
use crate::remote_calling::storage::{private_read, private_write};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;
use uuid::Uuid;

const FILE: &str = "/data/openu60-sms/notifications.json";

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Event {
    event_id: Uuid,
    message_id: String,
    sender: String,
    content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    message: Option<Value>,
}
impl Event {
    pub fn message(&self) -> Value {
        let mut value = json!({"type":"sms_event","eventId":self.event_id,"messageId":self.message_id,
            "sender":self.sender,"content":self.content});
        if let Some(message) = &self.message { value["message"] = message.clone(); }
        value
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    seen: Option<BTreeSet<String>>,
    pending: Vec<Event>,
}
pub struct SMSNotifications {
    file: PathBuf,
    state: Mutex<Result<Journal, &'static str>>,
    error: Mutex<Option<&'static str>>,
    pub changed: tokio::sync::Notify,
}
impl SMSNotifications {
    pub fn new() -> Self {
        Self::at(Path::new(FILE))
    }
    fn at(file: &Path) -> Self {
        let state = match std::fs::symlink_metadata(file) {
            Ok(_) => private_read(file)
                .map_err(|_| "sms_journal_read_failed")
                .and_then(|data| serde_json::from_slice(&data).map_err(|_| "invalid_sms_journal")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Journal::default()),
            Err(_) => Err("sms_journal_read_failed"),
        };
        Self {
            file: file.into(),
            changed: tokio::sync::Notify::new(),
            error: Mutex::new(state.as_ref().err().copied()),
            state: Mutex::new(state),
        }
    }
    fn save(&self, next: Journal, current: &mut Journal) -> Result<(), &'static str> {
        let data = serde_json::to_vec(&next).map_err(|_| "sms_journal_serialize_failed")?;
        if data.len() > 250000 {
            return Err("sms_notification_capacity");
        }
        private_write(&self.file, &data).map_err(|_| "sms_journal_write_failed")?;
        *current = next;
        Ok(())
    }
    fn poll(
        &self,
        snapshot: BTreeMap<String, u64>,
        fetch: impl Fn(u64) -> Result<Event, &'static str>,
    ) -> Result<(), &'static str> {
        let seen = self
            .state
            .lock()
            .unwrap()
            .as_ref()
            .map_err(|code| *code)?
            .seen
            .clone();
        let mut events = Vec::new();
        if let Some(seen) = &seen {
            for (key, id) in &snapshot {
                if !seen.contains(key) {
                    events.push(fetch(*id)?);
                }
            }
        }
        let mut state = self.state.lock().unwrap();
        let current = state.as_mut().map_err(|code| *code)?;
        let next_seen = snapshot.into_keys().collect();
        if current.seen.as_ref() == Some(&next_seen) && events.is_empty() {
            return Ok(());
        }
        let mut next = current.clone();
        let has_new_events = !events.is_empty();
        if next.pending.len() + events.len() > 128 {
            return Err("sms_notification_capacity");
        }
        next.seen = Some(next_seen);
        next.pending.extend(events);
        self.save(next, current)?;
        if has_new_events { self.changed.notify_one(); }
        Ok(())
    }
    pub fn pending(&self) -> Result<Vec<Event>, &'static str> {
        Ok(self
            .state
            .lock()
            .unwrap()
            .as_ref()
            .map_err(|code| *code)?
            .pending
            .iter()
            .take(16)
            .cloned()
            .collect())
    }
    pub fn test_notification(&self) -> (u16, Value) {
        let mut state = self.state.lock().unwrap();
        let current = match state.as_mut() {
            Ok(state) => state,
            Err(code) => return (503, json!({"ok":false,"error":code})),
        };
        if current.pending.len() >= 128 {
            return (503, json!({"ok":false,"error":"sms_notification_capacity"}));
        }
        let mut next = current.clone();
        next.pending.push(Event {
            event_id: Uuid::new_v4(),
            message_id: "0".into(),
            sender: "OpenU60 test".into(),
            content: base64::engine::general_purpose::STANDARD
                .encode("Test SMS 123456\n中文测试 🐼\nSent from your U60 Pro."),
            message: None,
        });
        match self.save(next, current) {
            Ok(()) => {
                self.changed.notify_one();
                (200, json!({"ok":true,"data":{"queued":true}}))
            },
            Err(code) => (503, json!({"ok":false,"error":code})),
        }
    }
    pub fn acknowledge(&self, id: Uuid) -> Result<(), &'static str> {
        let mut state = self.state.lock().unwrap();
        let current = state.as_mut().map_err(|code| *code)?;
        let mut next = current.clone();
        next.pending.retain(|event| event.event_id != id);
        if next.pending.len() == current.pending.len() {
            return Ok(());
        }
        self.save(next, current)
    }
    pub fn status(&self) -> Value {
        let state = self.state.lock().unwrap();
        match state.as_ref() {
            Ok(state) => {
                json!({"ok":true,"data":{"initialized":state.seen.is_some(),"pending":state.pending.len(),
                "lastError":*self.error.lock().unwrap()}})
            }
            Err(code) => json!({"ok":false,"error":code}),
        }
    }
    pub fn start(self: &Arc<Self>, events: mpsc::Receiver<Value>, recovery: Arc<crate::power::Recovery>, app: Arc<crate::handlers::AppState>) {
        let manager = self.clone();
        crate::system::spawn_named("sms-notifications", move || loop {
            if let Err(error) = app.sms_history.synchronize(&app) { eprintln!("[sms-line] {error}"); }
            let result = snapshot().and_then(|snapshot| manager.poll(snapshot, |id| fetch(id, &app)));
            let next = result.err();
            let mut last = manager.error.lock().unwrap();
            if next != *last {
                if let Some(code) = next {
                    eprintln!("[sms-notifications] {code}");
                }
            }
            *last = next;
            drop(last);
            loop {
                match events.recv_timeout(Duration::from_secs(60)) {
                    Ok(value) if value["wms_status"] == "new_sms_received" => {
                        if let Err(code) = recovery.notification() { eprintln!("[sms-notifications] {code}"); }
                        std::thread::sleep(Duration::from_millis(500));
                        break;
                    }
                    Ok(value) if value["resumed"] == true => break,
                    Ok(value) if matches!(value["phase"].as_str(), Some("leaving" | "changed")) => {
                        app.sms_history.sim_transition();
                        break;
                    }
                    Ok(_) => continue,
                    Err(mpsc::RecvTimeoutError::Timeout) => break,
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        std::thread::sleep(Duration::from_secs(60));
                        break;
                    }
                }
            }
        });
    }
}

fn snapshot() -> Result<BTreeMap<String, u64>, &'static str> {
    // Tag changes must not notify again. Date and store distinguish a reused row ID.
    let rows = query("SELECT id,hex(COALESCE(Mem_Store,'')||'/'||COALESCE(Year,'')||'/'||COALESCE(Month,'')||'/'||COALESCE(Day,'')||'/'||COALESCE(Hour,'')||'/'||COALESCE(Minute,'')||'/'||COALESCE(Second,'')) FROM sms WHERE Tag IN ('0','1') ORDER BY id LIMIT 2049;", 1048576)?;
    parse_snapshot(&rows)
}
fn parse_snapshot(rows: &str) -> Result<BTreeMap<String, u64>, &'static str> {
    let mut snapshot = BTreeMap::new();
    for row in rows.lines() {
        let (id, date) = row
            .trim_end()
            .split_once('\t')
            .ok_or("invalid_sms_metadata")?;
        let id: u64 = id.parse().map_err(|_| "invalid_sms_metadata")?;
        if id == 0 || date.len() > 512 || !date.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err("invalid_sms_metadata");
        }
        snapshot.insert(format!("{:x}", Sha256::digest(row.as_bytes())), id);
    }
    if snapshot.len() > 2048 {
        return Err("sms_snapshot_capacity");
    }
    Ok(snapshot)
}
fn fetch(id: u64, app: &crate::handlers::AppState) -> Result<Event, &'static str> {
    let row = query(&format!(
        "SELECT hex(Number),hex(Content),hex(substr('00'||Year,-2,2)||','||Month||','||Day||','||Hour||','||Minute||','||Second||','||TimeZone),Tag,hex(Mem_Store) FROM sms WHERE id={id} AND Tag IN ('0','1');"
    ), 1048576)?;
    let mut annotated = json!({"messages":[{"id":id}]});
    app.sms_history.decorate(app, &mut annotated).map_err(|_| "sms_event_line_unavailable")?;
    event_from_row(id, &row, annotated["messages"][0]["line"].clone())
}
fn event_from_row(id: u64, row: &str, line: Value) -> Result<Event, &'static str> {
    let fields: Vec<_> = row.trim_end_matches('\n').split('\t').collect();
    if fields.len() != 5 { return Err("sms_message_disappeared"); }
    let sender = decode(fields[0])?;
    let content = decode(fields[1])?;
    let date = decode(fields[2])?;
    let tag: u8 = fields[3].parse().map_err(|_| "invalid_sms_metadata")?;
    let store = decode(fields[4])?;
    if ![0, 1].contains(&tag) || date.len() > 64 || store.len() > 16 { return Err("invalid_sms_metadata"); }
    if sender.is_empty() || sender.len() > 128 || content.len() > 65536 {
        return Err("sms_message_too_large");
    }
    Ok(Event {
        event_id: Uuid::new_v4(),
        message_id: id.to_string(),
        sender,
        content: base64::engine::general_purpose::STANDARD.encode(content),
        message: Some(json!({"date":date,"tag":tag,"memStore":store,"groupId":"","line":line})),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn event(id: u64) -> Result<Event, &'static str> {
        Ok(Event {
            event_id: Uuid::new_v4(),
            message_id: id.to_string(),
            sender: "Synthetic".into(),
            content: base64::engine::general_purpose::STANDARD.encode("Test code 123456 中文 🐼"),
            message: None,
        })
    }
    #[tokio::test]
    async fn new_sms_wakes_delivery_only_after_persistence_and_resume_reuses_its_event_id() {
        let directory = std::env::temp_dir().join(format!("openu60-sms-wake-{}", Uuid::new_v4()));
        let file = directory.join("notifications.json");
        let manager = SMSNotifications::at(&file);
        manager.poll(BTreeMap::new(), event).unwrap();
        manager.poll(BTreeMap::from([("new".into(), 2)]), event).unwrap();
        tokio::time::timeout(Duration::from_millis(100), manager.changed.notified()).await.unwrap();
        let persisted = SMSNotifications::at(&file).pending().unwrap();
        assert_eq!(persisted.len(), 1);
        manager.poll(BTreeMap::from([("new".into(), 2)]), |_| panic!("resume must reuse the event")).unwrap();
        assert_eq!(manager.pending().unwrap()[0].event_id, persisted[0].event_id);
        manager.acknowledge(persisted[0].event_id).unwrap();
        assert!(SMSNotifications::at(&file).pending().unwrap().is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn existing_sms_seed_new_sms_survive_restart_and_ack_is_idempotent() {
        let directory = std::env::temp_dir().join(format!("openu60-sms-{}", Uuid::new_v4()));
        let file = directory.join("notifications.json");
        let manager = SMSNotifications::at(&file);
        manager
            .poll(BTreeMap::from([("old".into(), 1)]), |_| {
                panic!("Historical SMS must not notify")
            })
            .unwrap();
        let snapshot = BTreeMap::from([("old".into(), 1), ("new".into(), 2)]);
        manager.poll(snapshot.clone(), event).unwrap();
        let recovered = SMSNotifications::at(&file);
        let pending = recovered.pending().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].message_id, "2");
        assert!(String::from_utf8(
            base64::engine::general_purpose::STANDARD
                .decode(&pending[0].content)
                .unwrap()
        )
        .unwrap()
        .contains("123456 中文 🐼"));
        recovered
            .poll(snapshot, |_| panic!("Repeated snapshot"))
            .unwrap();
        recovered.acknowledge(pending[0].event_id).unwrap();
        recovered.acknowledge(pending[0].event_id).unwrap();
        assert!(SMSNotifications::at(&file).pending().unwrap().is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn wire_text_preserves_unicode_and_rejects_broken_encoding() {
        assert_eq!(decode("30303431344532444438334444433343").unwrap(), "A中🐼");
        assert_eq!(decode("5465737420313233343536").unwrap(), "Test 123456");
        assert!(decode("0G").is_err());
        assert!(decode("44383030").is_err());
    }
    #[test]
    fn metadata_changes_distinguish_a_reused_id() {
        let old = parse_snapshot("1\t32303235\n").unwrap();
        let next = parse_snapshot("1\t32303236\n").unwrap();
        assert_ne!(old.keys().next(), next.keys().next());
        assert!(parse_snapshot("not-an-id\txx\n").is_err());
    }
    #[test]
    fn test_notification_uses_the_durable_delivery_queue() {
        let directory = std::env::temp_dir().join(format!("openu60-sms-test-{}", Uuid::new_v4()));
        let file = directory.join("notifications.json");
        let manager = SMSNotifications::at(&file);
        assert_eq!(manager.test_notification().0, 200);
        let pending = SMSNotifications::at(&file).pending().unwrap();
        assert_eq!(pending.len(), 1);
        let message = pending[0].message();
        assert_eq!(message["sender"], "OpenU60 test");
        let content = base64::engine::general_purpose::STANDARD
            .decode(message["content"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            String::from_utf8(content).unwrap(),
            "Test SMS 123456\n中文测试 🐼\nSent from your U60 Pro."
        );
        std::fs::remove_dir_all(directory).unwrap();
    }
}
