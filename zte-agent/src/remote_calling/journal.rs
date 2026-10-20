use super::storage::{private_read, private_write};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Command {
    #[serde(rename = "type")]
    pub kind: String,
    pub request_id: Uuid,
    pub call_id: Uuid,
    pub action: String,
    pub expires_at: u64,
    pub number: Option<String>,
    pub digits: Option<String>,
}
impl Command {
    pub fn remaining(&self, now: u64) -> Result<std::time::Duration, &'static str> {
        let seconds = self
            .expires_at
            .checked_sub(now)
            .filter(|seconds| *seconds > 0)
            .ok_or("operation_expired")?;
        Ok(std::time::Duration::from_secs(seconds.min(20)))
    }
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.expires_at == 0
            || self.kind != "command"
            || !matches!(self.action.as_str(), "dial" | "answer" | "hangup" | "dtmf")
        {
            return Err("invalid_command");
        }
        if self.action == "dial" {
            let number = self.number.as_deref().ok_or("missing_number")?;
            if number.trim_start_matches('+').is_empty()
                || number.trim_start_matches('+').len() > 30
                || !number.bytes().enumerate().all(|(i, b)| {
                    b.is_ascii_digit() || b == b'*' || b == b'#' || (i == 0 && b == b'+')
                })
            {
                return Err("invalid_number");
            }
        }
        if self.action == "dtmf" {
            let digits = self.digits.as_deref().ok_or("missing_digits")?;
            if digits.is_empty()
                || digits.len() > 32
                || !digits
                    .bytes()
                    .all(|b| b.is_ascii_digit() || b"*#ABCD".contains(&b))
            {
                return Err("invalid_dtmf");
            }
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct Operation {
    call_id: Uuid,
    fingerprint: String,
    result: Option<Value>,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Data {
    operations: BTreeMap<Uuid, Operation>,
    order: Vec<Uuid>,
    pub call: Option<Call>,
    events: Vec<Value>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Call {
    pub id: Uuid,
    pub sequence: u64,
    pub state: String,
    pub number: Option<String>,
    pub media_ready: bool,
}

pub struct Journal {
    file: PathBuf,
    data: Data,
}
pub enum Begin {
    Execute,
    Replay(Value),
}
impl Journal {
    pub fn open(file: &Path) -> Result<Self, String> {
        let mut data: Data = if file.exists() {
            serde_json::from_slice(&private_read(file)?).map_err(|_| "invalid_call_journal")?
        } else {
            Data::default()
        };
        let mut recovered = false;
        for (id, operation) in &mut data.operations {
            if operation.result.is_none() {
                operation.result = Some(
                    json!({"type":"result", "requestId":id, "callId":operation.call_id, "ok":false,"error":"execution_unknown"}),
                );
                recovered = true;
            }
        }
        let journal = Self {
            file: file.into(),
            data,
        };
        if recovered {
            journal.persist()?;
        }
        Ok(journal)
    }
    fn persist(&self) -> Result<(), String> {
        private_write(
            &self.file,
            &serde_json::to_vec(&self.data).map_err(|_| "journal_serialize")?,
        )
    }
    pub fn begin(&mut self, command: &Command) -> Result<Begin, String> {
        command.validate()?;
        let fingerprint = format!(
            "{:x}",
            Sha256::digest(serde_json::to_vec(command).map_err(|_| "command_serialize")?)
        );
        if let Some(previous) = self.data.operations.get(&command.request_id) {
            if previous.fingerprint != fingerprint {
                return Err("operation_conflict".into());
            }
            return Ok(Begin::Replay(
                previous
                    .result
                    .clone()
                    .unwrap_or_else(|| result(command, Err("execution_unknown"))),
            ));
        }
        self.data.operations.insert(
            command.request_id,
            Operation {
                call_id: command.call_id,
                fingerprint,
                result: None,
            },
        );
        self.data.order.push(command.request_id);
        while self.data.order.len() > 128 {
            let id = self.data.order[0];
            if self
                .data
                .operations
                .get(&id)
                .is_some_and(|operation| operation.result.is_none())
            {
                break;
            }
            self.data.order.remove(0);
            self.data.operations.remove(&id);
        }
        self.persist()?;
        Ok(Begin::Execute)
    }
    pub fn complete(&mut self, command: &Command, value: Value) -> Result<(), String> {
        self.data
            .operations
            .get_mut(&command.request_id)
            .ok_or("operation_not_started")?
            .result = Some(value);
        self.persist()
    }
    pub fn call(&self) -> Option<Call> {
        self.data.call.clone()
    }
    pub fn start(&mut self, id: Uuid, state: &str, number: Option<String>) -> Result<(), String> {
        if self.data.call.as_ref().is_some_and(|call| call.id != id) {
            return Err("call_in_progress".into());
        }
        if self.data.call.is_none() {
            self.data.call = Some(Call {
                id,
                state: state.into(),
                sequence: 0,
                number,
                media_ready: false,
            });
            self.persist()?;
        }
        Ok(())
    }
    pub fn event(
        &mut self,
        state: &str,
        media: bool,
        reason: Option<&str>,
        observed_at: u64,
    ) -> Result<Value, String> {
        let call = self.data.call.as_mut().ok_or("no_active_call")?;
        call.sequence += 1;
        call.state = state.into();
        call.media_ready = media;
        let mut event = json!({"type":"event", "eventId":Uuid::new_v4(), "callId":call.id,
            "sequence":call.sequence, "state":state,"mediaReady":media,
            "observedAt":observed_at});
        if let Some(number) = &call.number {
            if !number.is_empty() {
                event["number"] = json!(number);
            }
        }
        if let Some(reason) = reason {
            event["reason"] = json!(reason);
        }
        if self.data.events.len() >= 64 {
            return Err("call_event_queue_full".into());
        }
        self.data.events.push(event.clone());
        self.persist()?;
        Ok(event)
    }
    pub fn finish(&mut self) -> Result<(), String> {
        self.data.call = None;
        self.persist()
    }
    pub fn events(&self) -> Vec<Value> {
        self.data.events.clone()
    }
    pub fn acknowledge(&mut self, id: &str) -> Result<(), String> {
        self.data
            .events
            .retain(|event| event["eventId"].as_str() != Some(id));
        self.persist()
    }
}
pub fn result(command: &Command, outcome: Result<(), &str>) -> Value {
    let mut value = json!({"type":"result","requestId":command.request_id,"callId":command.call_id,"ok":outcome.is_ok()});
    if let Err(error) = outcome {
        value["error"] = json!(error);
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (PathBuf, Command) {
        let directory = std::env::temp_dir().join(format!("openu60-synthetic-{}", Uuid::new_v4()));
        let command = Command {
            kind: "command".into(),
            request_id: Uuid::new_v4(),
            call_id: Uuid::new_v4(),
            action: "dial".into(),
            expires_at: 1_800_000_020,
            number: Some("+12345".into()),
            digits: None,
        };
        (directory, command)
    }
    #[test]
    fn command_deadlines_expire_and_never_exceed_the_delivery_window() {
        let (_, mut command) = fixture();
        for (expires, expected) in [
            (100, None),
            (101, Some(1)),
            (120, Some(20)),
            (999, Some(20)),
        ] {
            command.expires_at = expires;
            assert_eq!(
                command.remaining(100).ok().map(|value| value.as_secs()),
                expected
            );
        }
    }
    #[test]
    fn a_crash_after_start_never_reexecutes_a_dial() {
        let (directory, command) = fixture();
        let file = directory.join("journal.private.json");
        let mut first = Journal::open(&file).unwrap();
        assert!(matches!(first.begin(&command).unwrap(), Begin::Execute));
        drop(first);
        let mut restored = Journal::open(&file).unwrap();
        match restored.begin(&command).unwrap() {
            Begin::Replay(value) => assert_eq!(value["error"], "execution_unknown"),
            _ => panic!("dial would execute twice"),
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn a_completed_command_replays_its_result_and_rejects_changed_arguments() {
        let (directory, mut command) = fixture();
        let mut journal = Journal::open(&directory.join("journal.private.json")).unwrap();
        journal.begin(&command).unwrap();
        journal
            .complete(&command, result(&command, Ok(())))
            .unwrap();
        match journal.begin(&command).unwrap() {
            Begin::Replay(value) => assert_eq!(value["ok"], true),
            _ => panic!("completed operation was repeated"),
        }
        command.number = Some("54321".into());
        assert!(journal.begin(&command).is_err());
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn events_survive_restart_until_their_specific_acknowledgment() {
        let (directory, command) = fixture();
        let file = directory.join("journal.private.json");
        let mut journal = Journal::open(&file).unwrap();
        journal
            .start(command.call_id, "ringing", command.number)
            .unwrap();
        let event = journal.event("ringing", false, None, 1800000000).unwrap();
        drop(journal);
        let mut restored = Journal::open(&file).unwrap();
        assert_eq!(restored.events(), vec![event.clone()]);
        restored
            .acknowledge(event["eventId"].as_str().unwrap())
            .unwrap();
        assert!(Journal::open(&file).unwrap().events().is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }
}
