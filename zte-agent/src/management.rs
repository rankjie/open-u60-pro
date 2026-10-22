use crate::remote_calling::storage::{private_read, private_write};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Mutex,
};
use tiny_http::Method;
use uuid::Uuid;

const JOURNAL: &str = "/data/openu60-management/writes.json";
const BODY_LIMIT: usize = 65536;
const RESPONSE_LIMIT: usize = 524288;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    #[serde(rename = "type")]
    kind: Option<String>,
    pub request_id: Uuid,
    method: String,
    path: String,
    body: String,
    expires_at: u64,
}
impl Request {
    fn validate(&self, now: u64) -> Result<(Method, Vec<u8>), &'static str> {
        if self
            .kind
            .as_deref()
            .is_some_and(|kind| kind != "agent_request")
        {
            return Err("invalid_agent_request");
        }
        let method = match self.method.as_str() {
            "GET" => Method::Get,
            "POST" => Method::Post,
            "PUT" => Method::Put,
            "DELETE" => Method::Delete,
            _ => return Err("agent_method_forbidden"),
        };
        if self.path.len() > 256
            || !self.path.starts_with("/api/")
            || self.path.contains("//")
            || !self
                .path
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"/-".contains(&b))
            || [
                "auth",
                "remote-calling",
                "live-activity",
                "lan",
                "management",
                "identity",
                "calling",
            ]
            .iter()
            .any(|part| {
                self.path == format!("/api/{part}")
                    || self.path.starts_with(&format!("/api/{part}/"))
            })
        {
            return Err("agent_path_forbidden");
        }
        if self.expires_at <= now || self.expires_at > now.saturating_add(30) {
            return Err("agent_request_expired");
        }
        if self.body.len() > 87384 {
            return Err("agent_body_too_large");
        }
        let body = base64::engine::general_purpose::STANDARD
            .decode(&self.body)
            .map_err(|_| "invalid_agent_body")?;
        if body.len() > BODY_LIMIT || (method == Method::Get && !body.is_empty()) {
            return Err("invalid_agent_body");
        }
        Ok((method, body))
    }
    fn read_only(&self) -> bool {
        self.method == "GET"
            || (self.method == "POST" && (self.path == "/api/sms/list" || self.path == "/api/batch"))
    }
    fn fingerprint(&self) -> String {
        let mut hash = Sha256::new();
        // Transport clocks may differ before server synchronization; the effect
        // identity remains the same across LAN and relay delivery.
        for field in [&self.method, &self.path, &self.body] {
            hash.update(field.as_bytes());
            hash.update([0]);
        }
        format!("{:x}", hash.finalize())
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    sequence: u64,
    fingerprint: String,
    expires_at: u64,
    completed: bool,
    status: Option<u16>,
}
#[derive(Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    next_sequence: u64,
    entries: BTreeMap<Uuid, Entry>,
}

pub struct Management {
    file: PathBuf,
    lock: Mutex<()>,
    active: AtomicUsize,
}
impl Management {
    pub fn new() -> Self {
        Self::at(Path::new(JOURNAL))
    }
    fn at(file: &Path) -> Self {
        Self {
            file: file.into(),
            lock: Mutex::new(()),
            active: AtomicUsize::new(0),
        }
    }
    fn load(&self) -> Result<Journal, &'static str> {
        match std::fs::symlink_metadata(&self.file) {
            Ok(_) => serde_json::from_slice(
                &private_read(&self.file).map_err(|_| "agent_journal_read_failed")?,
            )
            .map_err(|_| "invalid_agent_journal"),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Journal::default()),
            Err(_) => Err("agent_journal_read_failed"),
        }
    }
    fn save(&self, data: &Journal) -> Result<(), &'static str> {
        let bytes = serde_json::to_vec(data).map_err(|_| "agent_journal_serialize_failed")?;
        private_write(&self.file, &bytes).map_err(|_| "agent_journal_write_failed")
    }
    pub fn handle(&self, bytes: &[u8], state: &crate::handlers::AppState) -> (u16, Value) {
        let request: Request = match serde_json::from_slice(bytes) {
            Ok(request) => request,
            Err(_) => return failure(400, "invalid_agent_request"),
        };
        let now = match state.remote_calling.unix_time() {
            Ok(now) => now,
            Err(code) => return failure(503, code),
        };
        self.execute(&request, now, |method, path, body| {
            crate::server::route(method, path, state, body)
        })
    }
    fn execute(
        &self,
        request: &Request,
        now: u64,
        run: impl FnOnce(&Method, &str, &[u8]) -> (u16, Value),
    ) -> (u16, Value) {
        if self.active.fetch_add(1, Ordering::AcqRel) >= 8 {
            self.active.fetch_sub(1, Ordering::AcqRel);
            return failure(429, "agent_busy");
        }
        struct Active<'a>(&'a AtomicUsize);
        impl Drop for Active<'_> {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _active = Active(&self.active);
        let (method, body) = match request.validate(now) {
            Ok(value) => value,
            Err(code) => return failure(400, code),
        };
        let fingerprint = request.fingerprint();
        if !request.read_only() {
            let _lock = self.lock.lock().expect("management journal lock poisoned");
            let mut data = match self.load() {
                Ok(data) => data,
                Err(code) => return failure(503, code),
            };
            if let Some(old) = data.entries.get(&request.request_id) {
                let code = if old.fingerprint != fingerprint {
                    "agent_request_conflict"
                } else if old.completed {
                    "agent_request_completed"
                } else {
                    "agent_outcome_unknown"
                };
                return (
                    409,
                    json!({"ok":false,"error":code,"originalStatus":old.status}),
                );
            }
            if data.entries.len() >= 1024 {
                // Clock correction must not evict a recently completed effect.
                // Unknown effects remain protected instead of becoming executable.
                let oldest = data
                    .entries
                    .iter()
                    .filter(|(_, entry)| entry.completed)
                    .min_by_key(|(_, entry)| entry.sequence)
                    .map(|(id, _)| *id);
                match oldest {
                    Some(id) => {
                        data.entries.remove(&id);
                    }
                    None => return failure(503, "agent_journal_capacity"),
                }
            }
            data.next_sequence = match data.next_sequence.checked_add(1) {
                Some(next) => next,
                None => return failure(503, "agent_journal_sequence_exhausted"),
            };
            data.entries.insert(
                request.request_id,
                Entry {
                    sequence: data.next_sequence,
                    fingerprint: fingerprint.clone(),
                    expires_at: request.expires_at,
                    completed: false,
                    status: None,
                },
            );
            if let Err(code) = self.save(&data) {
                return failure(503, code);
            }
        }
        let mut result = run(&method, &request.path, &body);
        if serde_json::to_vec(&result.1)
            .expect("JSON Value serialization")
            .len()
            > RESPONSE_LIMIT
        {
            result = failure(413, "agent_response_too_large");
        }
        if !request.read_only() {
            let _lock = self.lock.lock().expect("management journal lock poisoned");
            let mut data = match self.load() {
                Ok(data) => data,
                Err(_) => return failure(503, "agent_journal_read_failed_outcome_unknown"),
            };
            let entry = data
                .entries
                .get_mut(&request.request_id)
                .expect("claimed management request missing");
            assert_eq!(
                entry.fingerprint, fingerprint,
                "claimed management request changed"
            );
            entry.completed = true;
            entry.status = Some(result.0);
            if self.save(&data).is_err() {
                return failure(503, "agent_journal_write_failed_outcome_unknown");
            }
        }
        result
    }
}
fn failure(status: u16, code: &str) -> (u16, Value) {
    (status, json!({"ok":false,"error":code}))
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!("openu60-management-test-{}", Uuid::new_v4())))
        }
        fn manager(&self) -> Management {
            Management::at(&self.0.join("writes.json"))
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn request(method: &str, path: &str) -> Request {
        Request {
            kind: None,
            request_id: Uuid::new_v4(),
            method: method.into(),
            path: path.into(),
            body: String::new(),
            expires_at: 1020,
        }
    }
    #[test]
    fn local_and_relay_writes_share_one_durable_claim() {
        let fixture = Fixture::new();
        let manager = fixture.manager();
        let mut request = request("POST", "/api/sms/send");
        request.body = base64::engine::general_purpose::STANDARD
            .encode(br#"{"message_body":"synthetic-only"}"#);
        assert_eq!(
            manager
                .execute(&request, 1000, |_, _, _| (200, json!({"ok":true})))
                .0,
            200
        );
        request.kind = Some("agent_request".into());
        let (status, body) = fixture
            .manager()
            .execute(&request, 1001, |_, _, _| panic!("duplicate SMS send"));
        assert_eq!(status, 409);
        assert_eq!(body["error"], "agent_request_completed");
        let journal = std::fs::read_to_string(manager.file).unwrap();
        assert!(!journal.contains("synthetic-only") && !journal.contains(&request.body));
    }
    #[test]
    fn unfinished_work_is_never_resubmitted_after_restart() {
        let fixture = Fixture::new();
        let manager = fixture.manager();
        let request = request("PUT", "/api/usb/powerbank");
        assert!(
            std::panic::catch_unwind(|| manager.execute(&request, 1000, |_, _, _| panic!(
                "isolated synthetic process interruption"
            )))
            .is_err()
        );
        let (_, body) = fixture
            .manager()
            .execute(&request, 1001, |_, _, _| panic!("repeated device effect"));
        assert_eq!(body["error"], "agent_outcome_unknown");
    }
    #[test]
    fn expired_or_modified_requests_cannot_repeat_an_effect() {
        let fixture = Fixture::new();
        let manager = fixture.manager();
        let mut request = request("PUT", "/api/usb/powerbank");
        assert_eq!(
            manager
                .execute(&request, 1020, |_, _, _| panic!("expired effect"))
                .0,
            400
        );
        assert_eq!(
            manager
                .execute(&request, 1000, |_, _, _| (200, json!({})))
                .0,
            200
        );
        request.body = base64::engine::general_purpose::STANDARD.encode(b"{}");
        assert_eq!(
            manager
                .execute(&request, 1001, |_, _, _| panic!("modified effect"))
                .1["error"],
            "agent_request_conflict"
        );
    }
    #[test]
    fn reads_can_retry_without_persisting_their_contents() {
        let fixture = Fixture::new();
        let manager = fixture.manager();
        for (method, path) in [("GET", "/api/battery"), ("POST", "/api/sms/list"), ("POST", "/api/batch")] {
            let request = request(method, path);
            for _ in 0..2 {
                assert_eq!(
                    manager
                        .execute(&request, 1000, |_, _, _| (
                            200,
                            json!({"ok":true,"data":[]})
                        ))
                        .0,
                    200
                );
            }
        }
        assert!(!manager.file.exists());
    }
    #[test]
    fn clock_correction_cannot_forget_a_completed_effect() {
        let fixture = Fixture::new();
        let manager = fixture.manager();
        let mut request = request("PUT", "/api/usb/powerbank");
        assert_eq!(
            manager
                .execute(&request, 1000, |_, _, _| (200, json!({})))
                .0,
            200
        );
        request.expires_at = 1800000020;
        let result = fixture.manager().execute(&request, 1800000000, |_, _, _| {
            panic!("effect repeated after clock correction")
        });
        assert_eq!(result.1["error"], "agent_request_completed");
    }
    #[test]
    fn capacity_evicts_completed_history_but_preserves_unknown_effects() {
        let fixture = Fixture::new();
        let manager = fixture.manager();
        let unknown = request("POST", "/api/sms/send");
        let mut data = Journal {
            next_sequence: 1024,
            entries: BTreeMap::new(),
        };
        data.entries.insert(
            unknown.request_id,
            Entry {
                sequence: 0,
                fingerprint: unknown.fingerprint(),
                expires_at: 1020,
                completed: false,
                status: None,
            },
        );
        for sequence in 1..1024 {
            data.entries.insert(
                Uuid::new_v4(),
                Entry {
                    sequence,
                    fingerprint: "synthetic".into(),
                    expires_at: 1020,
                    completed: true,
                    status: Some(200),
                },
            );
        }
        manager.save(&data).unwrap();
        assert_eq!(
            manager
                .execute(&request("PUT", "/api/usb/powerbank"), 1000, |_, _, _| (
                    200,
                    json!({})
                ))
                .0,
            200
        );
        assert_eq!(manager.load().unwrap().entries.len(), 1024);
        assert_eq!(
            manager
                .execute(&unknown, 1000, |_, _, _| panic!("unknown effect replayed"))
                .1["error"],
            "agent_outcome_unknown"
        );
    }
    #[test]
    fn internal_routes_and_oversized_bodies_are_rejected_before_execution() {
        let fixture = Fixture::new();
        let manager = fixture.manager();
        for path in [
            "/api/auth/login",
            "/api/management",
            "/api/remote-calling/configure",
            "/api/lan/upload",
            "/api/../device",
            "https://foreign.invalid/api/device",
        ] {
            assert_eq!(
                manager
                    .execute(&request("POST", path), 1000, |_, _, _| panic!(
                        "forbidden request"
                    ))
                    .0,
                400
            );
        }
        let mut request = request("PUT", "/api/usb/powerbank");
        request.body = base64::engine::general_purpose::STANDARD.encode(vec![0; BODY_LIMIT + 1]);
        assert_eq!(
            manager
                .execute(&request, 1000, |_, _, _| panic!("oversized body"))
                .0,
            400
        );
    }
}
