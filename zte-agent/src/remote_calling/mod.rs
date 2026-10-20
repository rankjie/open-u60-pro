mod audio;
mod codec;
mod journal;
mod media;
pub(crate) mod storage;
mod worker;

use crate::handlers::AppState;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;
use uuid::Uuid;

const CONFIG: &str = "/data/openu60-calling/remote-calling.private.json";
const JOURNAL: &str = "/data/openu60-calling/calls.private.json";

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Config {
    enabled: bool,
    server_url: String,
    device_token: String,
    request_id: Uuid,
    endpoint_id: Option<Uuid>,
    invitation: Option<String>,
}
impl Config {
    fn validate(&self) -> Result<(), String> {
        server_url(&self.server_url)?;
        if self.device_token.len() != 43
            || !self
                .device_token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
        {
            return Err("invalid_device_token".into());
        }
        if self.endpoint_id.is_none() && self.invitation.as_ref().is_none_or(|v| v.len() != 43) {
            return Err("missing_invitation".into());
        }
        Ok(())
    }
}
#[derive(Default)]
struct Status {
    connected: bool,
    last_error: Option<String>,
    call_state: Option<String>,
}
pub struct RemoteCalling {
    clock: Mutex<Option<(u64, std::time::Instant)>>,
    local_commands: Mutex<Option<tokio::sync::mpsc::Sender<LocalCommand>>>,
    configure_lock: Mutex<()>,
    config: Mutex<Option<Config>>,
    status: Mutex<Status>,
    changed: Notify,
}
impl RemoteCalling {
    pub fn new() -> Self {
        let mut status = Status::default();
        let config = if Path::new(CONFIG).exists() {
            match storage::private_read(Path::new(CONFIG))
                .and_then(|bytes| {
                    serde_json::from_slice::<Config>(&bytes)
                        .map_err(|_| "invalid_remote_config".into())
                })
                .and_then(|config| {
                    config.validate()?;
                    Ok(config)
                }) {
                Ok(config) => Some(config),
                Err(error) => {
                    status.last_error = Some(error);
                    None
                }
            }
        } else {
            None
        };
        Self {
            clock: Mutex::new(None),
            local_commands: Mutex::new(None),
            configure_lock: Mutex::new(()),
            config: Mutex::new(config),
            status: Mutex::new(status),
            changed: Notify::new(),
        }
    }
    pub fn status(&self) -> Value {
        let agent_time = match self.unix_time() { Ok(time) => time, Err(code) => return json!({"ok":false,"error":code}) };
        let config = self.config.lock().unwrap();
        let status = self.status.lock().unwrap();
        json!({"ok":true,"data":{"agentTime":agent_time,"enabled":config.as_ref().is_some_and(|v|v.enabled),
            "configured":config.as_ref().is_some_and(|v|v.endpoint_id.is_some()),"connected":status.connected,
            "serverURL":config.as_ref().map(|v|&v.server_url),"routerId":config.as_ref().and_then(|v|v.endpoint_id),
            "lastError":status.last_error,"callState":status.call_state,"audioAdapterError":audio::available().err()}})
    }
    fn set_status(&self, connected: bool, error: Option<&str>, call: Option<&str>) {
        let mut status = self.status.lock().unwrap();
        status.connected = connected;
        status.last_error = error.map(String::from);
        status.call_state = call.map(String::from);
    }
    pub(crate) fn observe_time(&self, unix: u64) -> Result<(), &'static str> {
        if !(946684800..4102444800).contains(&unix) { return Err("invalid_server_clock"); }
        *self.clock.lock().unwrap() = Some((unix, std::time::Instant::now()));
        Ok(())
    }
    pub(crate) fn unix_time(&self) -> Result<u64, &'static str> {
        if let Some((unix, anchor)) = *self.clock.lock().unwrap() {
            return unix.checked_add(anchor.elapsed().as_secs()).ok_or("invalid_server_clock");
        }
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .map(|time|time.as_secs()).map_err(|_|"invalid_device_clock")
    }
    pub fn local_command(&self, bytes: &[u8]) -> (u16, Value) {
        let command: journal::Command = match serde_json::from_slice(bytes) {
            Ok(command) => command,
            Err(_) => return (400, json!({"ok":false,"error":"invalid_command"})),
        };
        let checked = command.validate().and_then(|_| {
            let now = self.unix_time()?;
            if command.expires_at > now.saturating_add(30) { return Err("operation_expiry_too_long"); }
            command.remaining(now).map(|_| ())
        });
        if let Err(code) = checked { return (400, json!({"ok":false,"error":code})); }
        let sender = self.local_commands.lock().unwrap().clone();
        let Some(sender) = sender else { return (503, json!({"ok":false,"error":"calling_worker_unavailable"})); };
        let id = command.request_id;
        let (ack, receipt) = std::sync::mpsc::sync_channel(1);
        if sender.try_send((command, ack)).is_err() { return (503, json!({"ok":false,"error":"calling_queue_unavailable"})); }
        match receipt.recv_timeout(Duration::from_secs(2)) {
            Ok(Ok(())) => (202, json!({"ok":true,"data":{"queued":true,"requestId":id}})),
            Ok(Err(code)) => (503, json!({"ok":false,"error":code})),
            Err(_) => (504, json!({"ok":false,"error":"calling_admission_unknown"})),
        }
    }
    fn persist(&self, config: Config) -> Result<(), String> {
        let mut current = self.config.lock().unwrap();
        storage::private_write(
            Path::new(CONFIG),
            &serde_json::to_vec(&config).map_err(|_| "config_serialize")?,
        )?;
        *current = Some(config);
        Ok(())
    }
    fn persist_enrollment(&self, config: Config) -> Result<(), String> {
        let mut current = self.config.lock().unwrap();
        if current
            .as_ref()
            .is_none_or(|value| !value.enabled || value.request_id != config.request_id)
        {
            return Err("configuration_changed".into());
        }
        storage::private_write(
            Path::new(CONFIG),
            &serde_json::to_vec(&config).map_err(|_| "config_serialize")?,
        )?;
        *current = Some(config);
        Ok(())
    }
    pub fn start(self: &Arc<Self>, state: Arc<AppState>) {
        let manager = self.clone();
        crate::system::spawn_named("remote-calling", move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(value) => value,
                Err(_) => {
                    manager.set_status(false, Some("runtime_start_failed"), None);
                    return;
                }
            };
            runtime.block_on(async {
                loop {
                    let config=manager.config.lock().unwrap().clone();
                    let Some(mut config)=config.filter(|config|config.enabled) else {manager.changed.notified().await;continue;};
                    if !state.auth.has_password() {manager.set_status(false,Some("agent_password_required"),None);manager.changed.notified().await;continue;}
                    if config.endpoint_id.is_none() {
                        let candidate=config.clone();
                        let enrolled=tokio::task::spawn_blocking(move ||enroll(candidate)).await;
                        match enrolled {
                            Ok(Ok(next))=>{
                                let current=manager.config.lock().unwrap().clone();
                                if current.as_ref().is_none_or(|c|!c.enabled || c.request_id!=next.request_id) {continue;}
                                if let Err(error)=manager.persist_enrollment(next.clone()) {manager.set_status(false,Some(&error),None);if error!="configuration_changed" {manager.changed.notified().await;}continue;}
                                config=next;
                            },
                            _=>{manager.set_status(false,Some("enrollment_failed"),None);tokio::select!{_=tokio::time::sleep(Duration::from_secs(10))=>{},_=manager.changed.notified()=>{}};continue;}
                        }
                    }
                    let mut worker=match worker::Worker::new(state.clone(),manager.clone(),config) {Ok(worker)=>worker,Err(error)=>{manager.set_status(false,Some(&error),None);manager.changed.notified().await;continue;}};
                    let outcome=worker.run().await;
                    let cleanup=worker.shutdown().await;
                    if let Err(error)=cleanup.and(outcome) {manager.set_status(false,Some(&error),None);manager.changed.notified().await;}
                }
            });
        });
    }
}

type LocalCommand = (journal::Command, std::sync::mpsc::SyncSender<Result<(), String>>);

fn server_url(value: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(value).map_err(|_| "invalid_server_url")?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("https_server_required".into());
    }
    Ok(url)
}
fn url(config: &Config, path: &str) -> Result<String, String> {
    Ok(format!(
        "{}/{}",
        config.server_url.trim_end_matches('/'),
        path
    ))
}
fn request(config: &Config, path: &str, body: Option<Value>) -> Result<Value, String> {
    let client = reqwest::blocking::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|_| "server_transport")?;
    let endpoint = url(config, path)?;
    let request = if let Some(body) = body {
        client.post(endpoint).json(&body)
    } else {
        client.get(endpoint)
    };
    let response = request
        .bearer_auth(&config.device_token)
        .send()
        .map_err(|_| "calling_server_unreachable")?;
    if !response.status().is_success() {
        return Err("calling_server_rejected".into());
    }
    if response.content_length().is_some_and(|size| size > 8192) {
        return Err("calling_server_response_too_large".into());
    }
    use std::io::Read;
    let mut bytes = Vec::new();
    response
        .take(8193)
        .read_to_end(&mut bytes)
        .map_err(|_| "server_response_read_failed")?;
    if bytes.len() > 8192 {
        return Err("calling_server_response_too_large".into());
    }
    serde_json::from_slice(&bytes).map_err(|_| "invalid_server_response".into())
}
fn enroll(mut config: Config) -> Result<Config, String> {
    let response = request(
        &config,
        "v1/enroll",
        Some(
            json!({"invitation":config.invitation,"deviceToken":config.device_token,"requestId":config.request_id}),
        ),
    )?;
    let id = Uuid::parse_str(
        response["endpointId"]
            .as_str()
            .ok_or("invalid_server_identity")?,
    )
    .map_err(|_| "invalid_server_identity")?;
    if response["routerId"].as_str() != Some(id.to_string().as_str())
        || response["role"] != "router"
    {
        return Err("invalid_server_identity".into());
    }
    config.endpoint_id = Some(id);
    config.invitation = None;
    Ok(config)
}
pub fn configure(state: &AppState, body: &[u8]) -> (u16, Value) {
    let _configure = state.remote_calling.configure_lock.lock().unwrap();
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields, rename_all = "camelCase")]
    struct Input {
        server_url: String,
        invitation: Option<String>,
    }
    let input = match serde_json::from_slice::<Input>(body) {
        Ok(input) => input,
        Err(_) => return error(400, "invalid_configuration"),
    };
    if state.call_active.load(Ordering::Relaxed)
        || state
            .remote_calling
            .status
            .lock()
            .unwrap()
            .call_state
            .is_some()
    {
        return error(409, "call_in_progress");
    }
    if let Err(code) = server_url(&input.server_url) {
        return error(400, &code);
    }
    let previous = state.remote_calling.config.lock().unwrap().clone();
    let mut config = match previous {
        Some(config) if config.server_url == input.server_url => config,
        Some(_) => return error(409, "server_change_requires_new_enrollment"),
        None => {
            use std::io::Read;
            let mut bytes = [0; 32];
            if std::fs::File::open("/dev/urandom")
                .and_then(|mut file| file.read_exact(&mut bytes))
                .is_err()
            {
                return error(500, "random_source_failed");
            }
            Config {
                enabled: true,
                server_url: input.server_url,
                device_token: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes),
                request_id: Uuid::new_v4(),
                endpoint_id: None,
                invitation: None,
            }
        }
    };
    config.enabled = true;
    if config.endpoint_id.is_none() {
        config.invitation = input.invitation;
    }
    if config.validate().is_err() {
        return error(400, "valid_invitation_required");
    }
    if let Err(code) = state.remote_calling.persist(config.clone()) {
        return error(500, &code);
    }
    if config.endpoint_id.is_none() {
        match enroll(config) {
            Ok(enrolled) => {
                if let Err(code) = state.remote_calling.persist_enrollment(enrolled) {
                    return error(500, &code);
                }
            }
            Err(code) => {
                state.remote_calling.changed.notify_one();
                return error(503, &code);
            }
        }
    }
    state.remote_calling.changed.notify_one();
    (200, state.remote_calling.status())
}
pub fn pairing(state: &AppState) -> (u16, Value) {
    let Some(config) = state
        .remote_calling
        .config
        .lock()
        .unwrap()
        .clone()
        .filter(|c| c.enabled && c.endpoint_id.is_some())
    else {
        return error(409, "remote_calling_not_configured");
    };
    match request(&config, "v1/pairings", Some(json!({}))) {
        Ok(data) => (200, json!({"ok":true,"data":data})),
        Err(code) => error(503, &code),
    }
}
pub fn disable(state: &AppState) -> (u16, Value) {
    let _configure = state.remote_calling.configure_lock.lock().unwrap();
    if state.call_active.load(Ordering::Relaxed)
        || state
            .remote_calling
            .status
            .lock()
            .unwrap()
            .call_state
            .is_some()
    {
        return error(409, "call_in_progress");
    }
    let config = state.remote_calling.config.lock().unwrap().clone();
    if let Some(mut config) = config {
        config.enabled = false;
        if let Err(code) = state.remote_calling.persist(config) {
            return error(500, &code);
        }
    }
    state.remote_calling.changed.notify_one();
    (200, state.remote_calling.status())
}
fn error(status: u16, code: &str) -> (u16, Value) {
    (status, json!({"ok":false,"error":code}))
}

#[cfg(test)]
mod clock_tests {
    use super::*;
    fn manager() -> RemoteCalling {
        // An isolated manager avoids opening the router's normal configuration.
        RemoteCalling { clock: Mutex::new(None), local_commands: Mutex::new(None), configure_lock: Mutex::new(()),
            config: Mutex::new(None), status: Mutex::new(Status::default()), changed: Notify::new() }
    }
    #[test]
    fn authenticated_server_time_advances_without_the_device_wall_clock() {
        let manager = manager();
        manager.observe_time(1800000000).unwrap();
        *manager.clock.lock().unwrap() = Some((1800000000, std::time::Instant::now() - Duration::from_secs(5)));
        assert!(manager.unix_time().unwrap() >= 1800000005);
    }
    #[test]
    fn invalid_time_does_not_replace_the_last_trusted_anchor() {
        let manager = manager(); manager.observe_time(1800000000).unwrap();
        for invalid in [0, 1234, u64::MAX] { assert_eq!(manager.observe_time(invalid), Err("invalid_server_clock")); }
        assert!(manager.unix_time().unwrap() >= 1800000000);
        assert!(manager.unix_time().unwrap() < 1800000100);
    }
    #[test]
    fn local_call_admission_waits_for_the_existing_command_owner() {
        let manager = manager(); manager.observe_time(1800000000).unwrap();
        let id = Uuid::new_v4();
        let (sender, mut receiver) = tokio::sync::mpsc::channel::<LocalCommand>(8);
        *manager.local_commands.lock().unwrap() = Some(sender);
        let owner = std::thread::spawn(move || {
            let (command, receipt) = receiver.blocking_recv().unwrap();
            assert_eq!(command.request_id, id);
            assert_eq!(command.action, "dial");
            receipt.send(Ok(())).unwrap();
        });
        let bytes = serde_json::to_vec(&json!({"type":"command","requestId":id,"callId":Uuid::new_v4(),
            "action":"dial","number":"12345","expiresAt":1800000020})).unwrap();
        let (status, value) = manager.local_command(&bytes);
        owner.join().unwrap();
        assert_eq!(status, 202); assert_eq!(value["data"]["requestId"], id.to_string());
        assert_eq!(manager.local_command(&bytes).0, 503);
        let mut expired: Value = serde_json::from_slice(&bytes).unwrap(); expired["expiresAt"] = json!(1700000000);
        assert_eq!(manager.local_command(&serde_json::to_vec(&expired).unwrap()).0, 400);
    }
}
