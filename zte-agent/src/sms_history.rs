//! SIM/number attribution kept separately from the firmware's SMS database.
use crate::{handlers::AppState, remote_calling::storage::{private_read, private_write}, cellular_line::CellularLine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::{Path, PathBuf}, sync::Mutex, time::{SystemTime, UNIX_EPOCH}};
use uuid::Uuid;

#[derive(Clone)]
struct Row { id: u64, key: String, payload: String, outgoing: bool, incoming: bool }
#[derive(Clone, PartialEq, Serialize, Deserialize)]
struct Pending { id: Uuid, payload: String, expires: u64, line: Option<CellularLine> }
#[derive(Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    entries: BTreeMap<String, Option<CellularLine>>,
    pending: Vec<Pending>,
}
struct State { journal: Result<Journal, String>, seeded: bool }
pub struct SMSHistory { file: PathBuf, state: Mutex<State> }

fn now() -> Result<u64, String> {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|v| v.as_secs()).map_err(|_| "sms_history_clock".into())
}
fn confirmed_line(before: Option<CellularLine>, after: Result<CellularLine, String>) -> Option<CellularLine> {
    match (before, after) {
        (Some(before), Ok(after)) if after.iccid == before.iccid => Some(before),
        (_, Err(error)) => { eprintln!("[sms-line] {error}"); None }
        _ => { eprintln!("[sms-line] sim_line_changed_or_unavailable_during_send"); None }
    }
}
fn payload(number: &str, content: &str) -> String {
    let number: String = number.chars().filter(|c| !c.is_whitespace() && !"-()".contains(*c)).collect();
    let mut hash = Sha256::new();
    hash.update((number.len() as u64).to_be_bytes()); hash.update(number.as_bytes()); hash.update(content.as_bytes());
    format!("{:x}", hash.finalize())
}
fn snapshot() -> Result<Vec<Row>, String> {
    let rows = crate::sms::query_database(
        "SELECT id,hex(COALESCE(Mem_Store,'')||'/'||COALESCE(Year,'')||'/'||COALESCE(Month,'')||'/'||COALESCE(Day,'')||'/'||COALESCE(Hour,'')||'/'||COALESCE(Minute,'')||'/'||COALESCE(Second,'')||'/'||COALESCE(TimeZone,'')),hex(Number),hex(Content),Tag FROM sms ORDER BY id;",
        32 * 1048576).map_err(str::to_string)?;
    parse_rows(&rows)
}
fn parse_rows(rows: &str) -> Result<Vec<Row>, String> {
    rows.lines().map(|row| {
        let fields: Vec<_> = row.split('\t').collect();
        if fields.len() != 5 { return Err("invalid_sms_history_row".into()); }
        let id = fields[0].parse::<u64>().ok().filter(|id| *id > 0).ok_or("invalid_sms_history_id")?;
        let number = crate::sms::decode_database_text(fields[2])?;
        let content = crate::sms::decode_database_text(fields[3])?;
        let payload = payload(&number, &content);
        let category = match fields[4] { "0" | "1" => "incoming", "2" | "3" => "outgoing", "4" => "draft", _ => return Err("invalid_sms_history_tag".into()) };
        let key = format!("{:x}", Sha256::digest(format!("{}\t{}\t{}\t{}", fields[0], fields[1], payload, category).as_bytes()));
        Ok(Row { id, key, payload, outgoing: category == "outgoing", incoming: category == "incoming" })
    }).collect()
}
impl SMSHistory {
    pub fn new() -> Self { Self::at(Path::new("/data/openu60-sms/lines.json")) }
    fn at(file: &Path) -> Self {
        let journal = match std::fs::symlink_metadata(file) {
            Ok(_) => private_read(file).and_then(|data| serde_json::from_slice(&data).map_err(|_| "invalid_sms_line_history".into())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Journal::default()),
            Err(_) => Err("sms_line_history_read".into()),
        };
        Self { file: file.into(), state: Mutex::new(State { journal, seeded: false }) }
    }
    fn save(&self, next: Journal, state: &mut State) -> Result<(), String> {
        let data = serde_json::to_vec(&next).map_err(|_| "sms_line_history_encode")?;
        if data.len() > 4 * 1048576 { return Err("sms_line_history_full".into()); }
        private_write(&self.file, &data)?;
        state.journal = Ok(next);
        Ok(())
    }
    fn reconcile(&self, state: &mut State, rows: &[Row], line: Option<&CellularLine>, time: u64) -> Result<(), String> {
        let current = state.journal.as_ref().map_err(Clone::clone)?;
        let mut next = current.clone();
        for row in rows {
            if next.entries.contains_key(&row.key) { continue; }
            let pending = row.outgoing.then(|| next.pending.iter().position(|send| send.payload == row.payload)).flatten();
            let captured = if let Some(index) = pending {
                let expected = next.pending[index].line.clone();
                if next.pending.iter().any(|send| send.payload == row.payload && send.line != expected) {
                    // Without a firmware send ID, cross-SIM identical pending sends are ambiguous.
                    for send in &mut next.pending { if send.payload == row.payload { send.line = None; } }
                    eprintln!("[sms-line] ambiguous_outgoing_message");
                }
                let send = next.pending.remove(index);
                if send.expires >= time { send.line } else { None }
            }
                else if state.seeded && row.incoming { line.cloned() } else { None };
            next.entries.insert(row.key.clone(), captured);
        }
        next.pending.retain(|send| send.expires >= time);
        // SIM-stored rows may disappear on a swap and return when that card is reinserted.
        // Keep attribution by full message identity, never by a reusable row ID alone.
        if &next != current { self.save(next, state)?; }
        state.seeded = true;
        Ok(())
    }
    fn sync_locked(&self, app: &AppState, state: &mut State) -> Result<Vec<Row>, String> {
        let rows = snapshot()?;
        let current = state.journal.as_ref().map_err(Clone::clone)?;
        let line = if state.seeded && rows.iter().any(|row| !current.entries.contains_key(&row.key)) {
            match crate::sim::capture_line(app) {
                Ok(line) => Some(line),
                Err(error) => { eprintln!("[sms-line] {error}"); None }
            }
        } else { None };
        self.reconcile(state, &rows, line.as_ref(), now()?)?;
        Ok(rows)
    }
    pub fn decorate(&self, app: &AppState, data: &mut Value) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        let rows = self.sync_locked(app, &mut state)?;
        let journal = state.journal.as_ref().map_err(Clone::clone)?;
        let lines: BTreeMap<_, _> = rows.iter().map(|row| (row.id, journal.entries.get(&row.key).cloned().flatten())).collect();
        for message in data["messages"].as_array_mut().ok_or("invalid_sms_list")? {
            let id = message["id"].as_u64().or_else(|| message["id"].as_str()?.parse().ok()).ok_or("invalid_sms_message_id")?;
            message["line"] = json!(lines.get(&id).ok_or("sms_message_disappeared")?);
        }
        Ok(())
    }
    pub fn send(&self, app: &AppState, request: &Value, send: impl FnOnce() -> Result<Value, String>) -> Result<Value, String> {
        let mut state = self.state.lock().unwrap();
        self.sync_locked(app, &mut state)?;
        let before = match crate::sim::capture_line(app) {
            Ok(line) => Some(line),
            Err(error) => { eprintln!("[sms-line] {error}"); None }
        };
        let number = request["number"].as_str().ok_or("invalid_sms_number")?;
        let content = request["message_body"].as_str().ok_or("invalid_sms_content")?;
        let content = crate::sms::decode_database_text(&content.bytes().map(|b| format!("{b:02X}")).collect::<String>())?;
        let id = Uuid::new_v4();
        let mut next = state.journal.as_ref().map_err(Clone::clone)?.clone();
        if next.pending.len() >= 128 { return Err("sms_send_attribution_full".into()); }
        // An interrupted send remains unattributed until the firmware result and SIM agree.
        next.pending.push(Pending { id, payload: payload(number, &content), expires: now()? + 300, line: None });
        self.save(next, &mut state)?;
        let result = send()?;
        let verified = confirmed_line(before, crate::sim::capture_line(app));
        let mut next = state.journal.as_ref().map_err(Clone::clone)?.clone();
        next.pending.iter_mut().find(|send| send.id == id).ok_or("sms_pending_line_missing")?.line = verified;
        // Sending has already succeeded. Persist/reconcile failures must not invite a resend.
        if let Err(error) = self.save(next, &mut state).and_then(|_| self.sync_locked(app, &mut state).map(|_| ())) {
            eprintln!("[sms-line] {error}");
        }
        Ok(result)
    }
    pub fn synchronize(&self, app: &AppState) -> Result<(), String> {
        self.sync_locked(app, &mut self.state.lock().unwrap()).map(|_| ())
    }
    pub fn sim_transition(&self) {
        self.state.lock().unwrap().seeded = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn line(suffix: &str, number: Option<&str>) -> CellularLine {
        CellularLine { iccid: format!("89000000000000{suffix}"), number: number.map(str::to_string), source: "manual".into() }
    }
    fn row(id: u64, version: u64, outgoing: bool) -> Row { Row { id, key: format!("{id}/{version}"), payload: format!("body/{id}"), outgoing, incoming: !outgoing } }
    #[test]
    fn confirmation_requires_the_same_sim_and_never_backfills_an_unknown_send() {
        let a = line("0001", Some("+12025550101")); let b = line("0002", Some("+12025550102"));
        assert_eq!(confirmed_line(Some(a.clone()), Ok(a.clone())), Some(a.clone()));
        assert_eq!(confirmed_line(Some(a.clone()), Ok(b)), None);
        assert_eq!(confirmed_line(None, Ok(a.clone())), None);
        assert_eq!(confirmed_line(Some(a), Err("sim_line_unavailable".into())), None);
    }
    #[test]
    fn message_identity_survives_read_changes_but_not_row_reuse_or_content_changes() {
        let original = parse_rows("1\t32303236\t313233\t48656C6C6F\t1\n").unwrap();
        let read = parse_rows("1\t32303236\t313233\t48656C6C6F\t0\n").unwrap();
        let reused = parse_rows("1\t32303237\t313233\t48656C6C6F\t1\n").unwrap();
        let changed = parse_rows("1\t32303236\t313233\t427965\t1\n").unwrap();
        assert_eq!(original[0].key, read[0].key);
        assert_ne!(original[0].key, reused[0].key);
        assert_ne!(original[0].key, changed[0].key);
        assert!(parse_rows("broken\n").is_err());
        assert_eq!(payload("+1 (202) 555-0101", "Hello"), payload("+12025550101", "Hello"));
    }
    #[test]
    fn ambiguous_identical_pending_sends_across_sim_changes_remain_unknown() {
        let dir = std::env::temp_dir().join(format!("sms-fifo-lines-{}", Uuid::new_v4()));
        let history = SMSHistory::at(&dir.join("lines.json"));
        let a = line("0001", Some("+12025550101")); let b = line("0002", Some("+12025550102"));
        let mut state = history.state.lock().unwrap();
        history.reconcile(&mut state, &[], None, 100).unwrap();
        let first = row(1, 1, true); let second = Row { payload: first.payload.clone(), ..row(2, 1, true) };
        let mut next = state.journal.as_ref().unwrap().clone();
        for line in [&a, &b] { next.pending.push(Pending { id: Uuid::new_v4(), payload: first.payload.clone(), expires: 200, line: Some(line.clone()) }); }
        history.save(next, &mut state).unwrap();
        history.reconcile(&mut state, &[first.clone(), second.clone()], Some(&b), 150).unwrap();
        assert_eq!(state.journal.as_ref().unwrap().entries[&first.key], None);
        assert_eq!(state.journal.as_ref().unwrap().entries[&second.key], None);
        drop(state); std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn history_freezes_each_line_leaves_legacy_unknown_and_survives_swaps_and_restarts() {
        let dir = std::env::temp_dir().join(format!("sms-lines-{}", Uuid::new_v4()));
        let history = SMSHistory::at(&dir.join("lines.json"));
        let a = line("0001", Some("+12025550101")); let b = line("0002", None);
        let old = row(1, 1, false); let incoming = row(2, 1, false); let sent = row(3, 1, true);
        {
            let mut state = history.state.lock().unwrap();
            history.reconcile(&mut state, &[old.clone()], Some(&a), 100).unwrap();
            history.reconcile(&mut state, &[old.clone(), incoming.clone()], Some(&a), 101).unwrap();
            let mut next = state.journal.as_ref().unwrap().clone();
            next.pending.push(Pending { id: Uuid::new_v4(), payload: sent.payload.clone(), expires: 200, line: Some(b.clone()) });
            history.save(next, &mut state).unwrap();
            history.reconcile(&mut state, &[old.clone(), incoming.clone(), sent.clone()], Some(&b), 102).unwrap();
            let entries = &state.journal.as_ref().unwrap().entries;
            assert_eq!(entries[&old.key], None);
            assert_eq!(entries[&incoming.key], Some(a.clone()));
            assert_eq!(entries[&sent.key], Some(b.clone()));
        }
        let restored = SMSHistory::at(&history.file);
        let mut state = restored.state.lock().unwrap();
        let offline = row(4, 1, false);
        restored.reconcile(&mut state, &[incoming.clone(), sent.clone(), offline.clone()], Some(&b), 104).unwrap();
        assert_eq!(state.journal.as_ref().unwrap().entries[&incoming.key], Some(a));
        assert_eq!(state.journal.as_ref().unwrap().entries[&offline.key], None, "Unobserved offline arrivals have no proven line");
        let reused = row(2, 2, false);
        restored.reconcile(&mut state, &[reused.clone(), sent.clone()], Some(&b), 105).unwrap();
        assert_eq!(state.journal.as_ref().unwrap().entries[&reused.key], Some(b));
        assert_eq!(state.journal.as_ref().unwrap().entries[&incoming.key].as_ref().unwrap().number.as_deref(), Some("+12025550101"));
        drop(state); std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn delayed_outgoing_rows_keep_the_sending_line_and_expired_attempts_are_not_reused() {
        let dir = std::env::temp_dir().join(format!("sms-send-lines-{}", Uuid::new_v4()));
        let history = SMSHistory::at(&dir.join("lines.json")); let a = line("0001", Some("+12025550101")); let b = line("0002", Some("+12025550102"));
        let mut state = history.state.lock().unwrap();
        history.reconcile(&mut state, &[], None, 100).unwrap();
        let sent = row(1, 1, true);
        let mut next = state.journal.as_ref().unwrap().clone();
        next.pending.push(Pending { id: Uuid::new_v4(), payload: sent.payload.clone(), expires: 200, line: Some(a.clone()) });
        history.save(next, &mut state).unwrap();
        history.reconcile(&mut state, &[sent.clone()], Some(&b), 150).unwrap();
        assert_eq!(state.journal.as_ref().unwrap().entries[&sent.key], Some(a));
        let expired = row(2, 1, true);
        let mut next = state.journal.as_ref().unwrap().clone();
        next.pending.push(Pending { id: Uuid::new_v4(), payload: expired.payload.clone(), expires: 151, line: None });
        history.save(next, &mut state).unwrap();
        history.reconcile(&mut state, &[sent, expired.clone()], Some(&b), 152).unwrap();
        assert_eq!(state.journal.as_ref().unwrap().entries[&expired.key], None);
        assert!(state.journal.as_ref().unwrap().pending.is_empty());
        drop(state); std::fs::remove_dir_all(dir).unwrap();
    }
}
