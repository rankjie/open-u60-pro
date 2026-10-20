use crate::remote_calling::storage::{private_read, private_write};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};
use uuid::Uuid;

const FILE: &str = "/data/openu60-sms/notifications.json";
const DATABASE: &str = "/etc_rw/ztembb/ztesms/sms_db/sms.db";

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Event {
    event_id: Uuid,
    message_id: String,
    sender: String,
    content: String,
}
impl Event {
    pub fn message(&self) -> Value {
        json!({"type":"sms_event","eventId":self.event_id,"messageId":self.message_id,
            "sender":self.sender,"content":self.content})
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
        if next.pending.len() + events.len() > 128 {
            return Err("sms_notification_capacity");
        }
        next.seen = Some(next_seen);
        next.pending.extend(events);
        self.save(next, current)
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
    pub fn start(self: &Arc<Self>, events: mpsc::Receiver<Value>) {
        let manager = self.clone();
        crate::system::spawn_named("sms-notifications", move || loop {
            let result = snapshot().and_then(|snapshot| manager.poll(snapshot, fetch));
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
                        std::thread::sleep(Duration::from_millis(500));
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

fn query(sql: &str) -> Result<String, &'static str> {
    let mut child = Command::new("/usr/bin/sqlite3")
        .args([
            "-cmd",
            ".timeout 2000",
            "-readonly",
            "-separator",
            "\t",
            DATABASE,
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
        stdout.take(1048577).read_to_end(&mut bytes).map(|_| bytes)
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
    if bytes.len() > 1048576 {
        return Err("sms_database_response_too_large");
    }
    String::from_utf8(bytes).map_err(|_| "invalid_sms_metadata")
}
fn snapshot() -> Result<BTreeMap<String, u64>, &'static str> {
    // Tag changes must not notify again. Date and store distinguish a reused row ID.
    let rows = query("SELECT id,hex(COALESCE(Mem_Store,'')||'/'||COALESCE(Year,'')||'/'||COALESCE(Month,'')||'/'||COALESCE(Day,'')||'/'||COALESCE(Hour,'')||'/'||COALESCE(Minute,'')||'/'||COALESCE(Second,'')) FROM sms WHERE Tag IN ('0','1') ORDER BY id LIMIT 2049;")?;
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
fn fetch(id: u64) -> Result<Event, &'static str> {
    let row = query(&format!(
        "SELECT hex(Number),hex(Content) FROM sms WHERE id={id} AND Tag IN ('0','1');"
    ))?;
    let (sender, content) = row
        .trim_end_matches('\n')
        .split_once('\t')
        .ok_or("sms_message_disappeared")?;
    let sender = decode(sender)?;
    let content = decode(content)?;
    if sender.is_empty() || sender.len() > 128 || content.len() > 65536 {
        return Err("sms_message_too_large");
    }
    Ok(Event {
        event_id: Uuid::new_v4(),
        message_id: id.to_string(),
        sender,
        content: base64::engine::general_purpose::STANDARD.encode(content),
    })
}
fn decode(value: &str) -> Result<String, &'static str> {
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

#[cfg(test)]
mod tests {
    use super::*;
    fn event(id: u64) -> Result<Event, &'static str> {
        Ok(Event {
            event_id: Uuid::new_v4(),
            message_id: id.to_string(),
            sender: "Synthetic".into(),
            content: base64::engine::general_purpose::STANDARD.encode("Test code 123456 中文 🐼"),
        })
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
}
