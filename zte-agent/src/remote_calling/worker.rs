use super::{
    audio,
    journal::{result, Begin, Command, Journal},
    media::Media,
    Config, RemoteCalling,
};
use crate::{at_cmd, handlers::AppState, telephony};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest, protocol::WebSocketConfig, Message,
};
use uuid::Uuid;
use webrtc::ice_transport::ice_server::RTCIceServer;

enum Network {
    Message(Value),
    Offline(&'static str),
}
enum Work {
    Status(Result<Vec<Value>, &'static str>),
    Command(Command, Result<(), &'static str>, bool),
    Cleanup(Result<(), &'static str>),
}
struct Execution {
    cancelled: Arc<AtomicBool>,
    deadline: JoinHandle<()>,
}
impl Execution {
    fn new(remaining: Duration) -> Self {
        let cancelled = Arc::new(AtomicBool::new(false));
        let flag = cancelled.clone();
        let deadline = tokio::spawn(async move {
            tokio::time::sleep(remaining).await;
            flag.store(true, Ordering::Release);
        });
        Self {
            cancelled,
            deadline,
        }
    }
    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}
impl Drop for Execution {
    fn drop(&mut self) {
        self.cancel();
        self.deadline.abort();
    }
}

pub struct Worker {
    state: Arc<AppState>,
    manager: Arc<RemoteCalling>,
    recovery: Arc<crate::power::Recovery>,
    config: Config,
    journal: Journal,
    media: Option<Media>,
    peers: HashMap<Uuid, super::peer::Peer>,
    connect_identity: Arc<super::connect::Identity>,
    network: Option<JoinHandle<()>>,
    connected: bool,
    paired: bool,
    signals: mpsc::Sender<Value>,
    outgoing: Option<mpsc::Receiver<Value>>,
    ice: Vec<RTCIceServer>,
    failures: mpsc::Sender<super::media::Failure>,
    failure_rx: mpsc::Receiver<super::media::Failure>,
    waiting: Option<(Command, Instant)>,
    queue: VecDeque<Command>,
    inflight: Option<Command>,
    execution: Option<Execution>,
    admitted: HashMap<Uuid, Instant>,
    work: Option<oneshot::Receiver<Work>>,
    next_poll: Instant,
    next_sms: Instant,
    call_started: Instant,
    cleanup: Option<&'static str>,
    modem_seen: bool,
    modem_active: bool,
    physical_id: Option<i64>,
    physical_direction: Option<String>,
    local_commands: mpsc::Receiver<super::LocalCommand>,
}
impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(call)=self.journal.call() {
            let result=self.manager.unix_time().map_err(String::from).and_then(|now|self.manager.recordings.observe(
                call.id,call.number.clone(),self.physical_direction.as_deref()==Some("mt"),"ended",now,Some("calling_worker_stopped"),call.line.clone()));
            if let Err(error)=result {self.manager.recordings.note_error(error);}
            self.manager.recordings.stop(call.id);
        }
    }
}
impl Worker {
    pub fn new(
        state: Arc<AppState>,
        manager: Arc<RemoteCalling>,
        config: Config,
        recovery: Arc<crate::power::Recovery>,
    ) -> Result<Self, String> {
        let journal = Journal::open(std::path::Path::new(super::JOURNAL))?;
        let connect_identity = Arc::new(super::connect::Identity::load()?);
        let (signals, outgoing) = mpsc::channel(64);
        let (failures, failure_rx) = mpsc::channel(8);
        let (local_sender, local_commands) = mpsc::channel(8);
        *manager.local_commands.lock().unwrap() = Some(local_sender);
        Ok(Self {
            state,
            manager,
            recovery,
            config,
            journal,
            media: None,
            peers: HashMap::new(),
            connect_identity,
            network: None,
            connected: false,
            paired: false,
            signals,
            outgoing: Some(outgoing),
            ice: vec![],
            failures,
            failure_rx,
            waiting: None,
            queue: VecDeque::new(),
            inflight: None,
            execution: None,
            admitted: HashMap::new(),
            work: None,
            next_poll: Instant::now(),
            next_sms: Instant::now(),
            call_started: Instant::now(),
            cleanup: None,
            modem_seen: false,
            modem_active: false,
            physical_id: None,
            physical_direction: None,
            local_commands,
        })
    }
    pub async fn run(&mut self) -> Result<(), String> {
        let (events, mut incoming) = mpsc::channel(64);
        let config = self.config.clone();
        let mut resumed = self.recovery.subscribe();
        let outgoing = self.outgoing.take().ok_or("network_already_started")?;
        self.network = Some(tokio::spawn(connection(config, self.manager.clone(), outgoing, events, resumed.clone())));
        // A modem ID may be reused while the agent is stopped. Do not redial or
        // hang up an unidentified physical call when recovering an old session.
        if self.journal.call().is_some() {
            self.journal
                .event("ended", false, Some("agent_restarted"), self.manager.unix_time()?)?;
            self.journal.finish()?;
        }
        let mut tick = tokio::time::interval(Duration::from_millis(100));
        loop {
            tokio::select! {
                _ = self.manager.changed.notified() => return Ok(()),
                change = resumed.changed() => {
                    change.map_err(|_| "wake_recovery_channel_closed")?;
                    self.next_poll = Instant::now();
                    self.next_sms = Instant::now();
                },
                _ = self.state.sms_notifications.changed.notified() => self.next_sms = Instant::now(),
                message = incoming.recv() => match message.ok_or("network_worker_stopped")? {
                    Network::Offline(error) => { self.connected = false; self.close_peers().await; self.status(Some(error)); },
                    Network::Message(value) => self.message(value).await?,
                },
                local = self.local_commands.recv() => {
                    let (command, ack) = local.ok_or("local_command_channel_closed")?;
                    if !self.connected {
                        let _ = ack.send(Err("calling_server_disconnected".into()));
                    } else {
                        let value = serde_json::to_value(command).map_err(|_| "invalid_local_command")?;
                        let outcome = self.message(value).await;
                        let _ = ack.send(outcome.clone());
                        outcome?;
                    }
                },
                error = self.failure_rx.recv() => {
                    let (generation, error) = error.ok_or("media_worker_stopped")?;
                    if self.media.as_ref().is_some_and(|media| media.generation == generation) {
                        if self.journal.call().is_some() { self.cleanup = Some(error); } self.status(Some(error));
                    }
                },
                _ = tick.tick() => self.tick().await?,
            }
        }
    }
    fn status(&self, error: Option<&str>) {
        let call = self.journal.call();
        if let Some(call)=&call {
            let result=self.manager.unix_time().map_err(String::from).and_then(|now|self.manager.recordings.observe(
                call.id,call.number.clone(),self.physical_direction.as_deref()==Some("mt")||call.state=="ringing",&call.state,now,error,call.line.clone()));
            if let Err(error)=result {self.manager.recordings.note_error(error);}
        }
        self.manager.set_status(
            self.connected,
            error,
            call.as_ref().map(|call| call.state.as_str()),
        );
    }
    async fn send(&self, value: Value) -> Result<(), String> {
        self.signals
            .send(value)
            .await
            .map_err(|_| "network_worker_stopped".into())
    }
    fn record_phone(&self, command: &Command) {
        self.status(None);
        if let Some(phone) = &command.phone {
            if let Err(error) = self.manager.recordings.assign_phone(command.call_id, phone) {
                self.manager.recordings.note_error(error);
            }
        }
    }
    async fn event(
        &mut self,
        state: &str,
        media: bool,
        reason: Option<&str>,
    ) -> Result<(), String> {
        let event = self.journal.event(state, media, reason, self.manager.unix_time()?)?;
        self.send(event).await?;
        self.status(reason);
        Ok(())
    }
    async fn completed(
        &mut self,
        command: &Command,
        outcome: Result<(), &str>,
    ) -> Result<(), String> {
        self.admitted.remove(&command.request_id);
        let value = result(command, outcome);
        self.journal.complete(command, value.clone())?;
        self.send(value).await
    }
    async fn new_media(&mut self, id: Uuid) -> Result<(), String> {
        if let Some(media) = self.media.take() {
            media.close().await;
        }
        let media = Media::new(
            id,
            self.ice.clone(),
            self.signals.clone(),
            self.failures.clone(),
        )
        .await?;
        media.offer(&self.signals).await?;
        self.media = Some(media);
        Ok(())
    }
    async fn message(&mut self, value: Value) -> Result<(), String> {
        match value["type"].as_str().ok_or("invalid_server_message")? {
            "connect_request" => {
                let id = value["requestId"].as_str().and_then(|v|Uuid::parse_str(v).ok()).ok_or("invalid_connection_id")?;
                let router = self.config.endpoint_id.ok_or("missing_router_identity")?;
                let token = value["phoneToken"].as_str().ok_or("invalid_connection_token")?.to_string();
                let state = self.state.clone(); let identity = self.connect_identity.clone(); let signals = self.signals.clone();
                tokio::spawn(async move {
                    let result = tokio::task::spawn_blocking(move || {
                        let now = state.remote_calling.unix_time()?;
                        identity.authorize(&value, router, now, |password|state.auth.verify_password(password))
                    }).await;
                    let (ok, error) = match result {
                        Ok(Ok(true)) => (true, None),
                        Ok(Ok(false)) => (false, Some("incorrect_router_password")),
                        Ok(Err(code)) => (false, Some(code)),
                        Err(_) => { eprintln!("[connect] verification worker failed"); (false, Some("connection_verification_failed")) },
                    };
                    let _ = signals.send(json!({"type":"connect_result","requestId":id,"phoneToken":token,"ok":ok,"error":error})).await;
                });
            }
            "peer_session" => {
                let id = value["sessionId"].as_str().and_then(|v|Uuid::parse_str(v).ok()).ok_or("invalid_peer_session")?;
                let opened: Result<(), &'static str> = async {
                    let router = value["routerId"].as_str().and_then(|v|Uuid::parse_str(v).ok()).ok_or("invalid_peer_router")?;
                    let phone = value["phoneId"].as_str().and_then(|v|Uuid::parse_str(v).ok()).ok_or("invalid_peer_phone")?;
                    let expires = value["expiresAt"].as_u64().ok_or("invalid_peer_expiry")?;
                    let now = self.manager.unix_time()?;
                    if Some(router) != self.config.endpoint_id || expires <= now || expires > now + 302 { return Err("invalid_peer_session"); }
                    let ice = super::peer::ice_servers(&value["iceServers"])?;
                    if self.peers.len() >= 8 || self.peers.contains_key(&id) { return Err("peer_capacity"); }
                    let peer = super::peer::Peer::new(id, router, phone, expires, ice, self.state.clone(), self.signals.clone()).await?;
                    self.peers.insert(id, peer);
                    Ok(())
                }.await;
                if let Err(code) = opened {
                    eprintln!("[peer] {code}"); self.send(json!({"type":"peer_close","sessionId":id})).await?;
                }
            }
            "peer_signal" => {
                let id = value["sessionId"].as_str().and_then(|v|Uuid::parse_str(v).ok()).ok_or("invalid_peer_session")?;
                if let Some(peer) = self.peers.get_mut(&id) {
                    if let Err(code) = peer.signal(&value).await {
                        eprintln!("[peer] {code}");
                        self.peers.remove(&id).unwrap().close().await;
                        self.send(json!({"type":"peer_close","sessionId":id})).await?;
                    }
                }
            }
            "peer_closed" => {
                let id = value["sessionId"].as_str().and_then(|v|Uuid::parse_str(v).ok()).ok_or("invalid_peer_session")?;
                if let Some(peer) = self.peers.remove(&id) { peer.close().await; }
            }
            "agent_request" => {
                let request_id = value["requestId"].as_str().ok_or("invalid_management_id")?.to_string();
                Uuid::parse_str(&request_id).map_err(|_| "invalid_management_id")?;
                let bytes = serde_json::to_vec(&value).map_err(|_| "invalid_management_request")?;
                if bytes.len() > 98304 { return Err("management_request_too_large".into()); }
                let state = self.state.clone(); let signals = self.signals.clone();
                tokio::spawn(async move {
                    let outcome = tokio::task::spawn_blocking(move || state.management.handle(&bytes, &state)).await;
                    let (status, body) = match outcome {
                        Ok(outcome) => outcome,
                        Err(_) => { eprintln!("[management] request worker failed"); (500, json!({"ok":false,"error":"agent_execution_unknown"})) },
                    };
                    use base64::Engine;
                    let body = serde_json::to_vec(&body).expect("JSON Value serialization");
                    let _ = signals.send(json!({"type":"agent_result","requestId":request_id,"status":status,"body":base64::engine::general_purpose::STANDARD.encode(body)})).await;
                });
            }
            "hello" => {
                self.next_sms = Instant::now();
                if value["protocol"] != 1
                    || value["role"] != "router"
                    || value["endpointId"].as_str()
                        != self.config.endpoint_id.map(|id| id.to_string()).as_deref()
                {
                    return Err("invalid_server_identity".into());
                }
                self.manager.observe_time(value["serverTime"].as_u64().ok_or("invalid_server_clock")?)?;
                self.ice = serde_json::from_value(value["iceServers"].clone())
                    .map_err(|_| "invalid_ice_servers")?;
                // Older servers advertise no doors; a malformed entry is skipped, not trusted.
                let doors: Vec<String> = value["doors"].as_array().map(|doors| doors.iter()
                    .filter_map(|door| door["address"].as_str())
                    .filter(|address| relay_tunnel::Door::parse(address).is_ok())
                    .map(String::from).collect()).unwrap_or_default();
                if let Err(error) = self.manager.update_doors(doors) { eprintln!("[doors] {error}"); }
                self.connected = true;
                self.close_peers().await;
                self.send(json!({"type":"peer_register","connectionKey":self.connect_identity.public_key()})).await?;
                let calls = value["calls"].as_array().ok_or("invalid_server_calls")?;
                if self.journal.call().is_some_and(|call| {
                    !calls.iter().any(|snapshot| {
                        snapshot["callId"].as_str() == Some(call.id.to_string().as_str())
                    })
                }) {
                    self.cleanup = Some("server_session_ended");
                }
                self.paired = value["paired"].as_bool().ok_or("invalid_pairing_state")?;
                for event in self.journal.events() {
                    self.send(event).await?;
                }
                self.status(None);
            }
            "ice_servers" => {
                self.ice = serde_json::from_value(value["iceServers"].clone())
                    .map_err(|_| "invalid_ice_servers")?;
            }
            "paired" => self.paired = true,
            "unpaired" => self.paired = false,
            "command" => {
                let command: Command =
                    serde_json::from_value(value).map_err(|_| "invalid_server_command")?;
                command.validate()?;
                if self
                    .waiting
                    .as_ref()
                    .is_some_and(|(c, _)| c.request_id == command.request_id)
                    || self
                        .inflight
                        .as_ref()
                        .is_some_and(|c| c.request_id == command.request_id)
                    || self
                        .queue
                        .iter()
                        .any(|c| c.request_id == command.request_id)
                {
                    return Ok(());
                }
                match self.journal.begin(&command)? {
                    Begin::Replay(result) => self.send(result).await?,
                    Begin::Execute => {
                        self.admitted.insert(command.request_id, Instant::now());
                        if command.action == "hangup" {
                            self.cancel_commands(command.call_id, "call_cancelled")
                                .await?;
                        }
                        if self.queue.len() >= 8 {
                            self.completed(&command, Err("command_queue_full")).await?;
                        } else {
                            self.queue.push_back(command);
                        }
                    }
                }
            }
            "signal" => {
                if let Some(media) = self.media.as_mut() {
                    if value["callId"].as_str() == Some(media.call_id.to_string().as_str()) {
                        if let Err(error) = media.signal(&value).await {
                            self.cleanup = Some(error);
                            self.status(Some(error));
                        }
                    }
                }
            }
            "media_request" => {
                if let Some(call) = self.journal.call() {
                    if value["callId"].as_str() == Some(call.id.to_string().as_str()) {
                        if self.new_media(call.id).await.is_err() {
                            self.cleanup = Some("media_prepare_failed");
                        } else if call.media_ready {
                            self.event(&call.state, false, None).await?;
                        }
                    }
                }
            }
            "event_ack" => self
                .journal
                .acknowledge(value["eventId"].as_str().ok_or("invalid_event_ack")?)?,
            "sms_ack" => {
                let id = value["eventId"].as_str().and_then(|id| Uuid::parse_str(id).ok()).ok_or("invalid_sms_ack")?;
                if let Err(code) = self.state.sms_notifications.acknowledge(id) { eprintln!("[sms-notifications] {code}"); }
            }
            "call" => {
                if value["state"] == "ended" {
                    let id =
                        Uuid::parse_str(value["callId"].as_str().ok_or("invalid_call_identity")?)
                            .map_err(|_| "invalid_call_identity")?;
                    self.cancel_commands(id, "session_ended").await?;
                }
            }
            "error" => {
                let code = value["error"].as_str().ok_or("invalid_server_error")?;
                if code != "peer_offline" && code != "call_ended" {
                    self.status(Some("calling_server_rejected"));
                }
            }
            "pong" => {}
            _ => return Err("unknown_server_message".into()),
        }
        Ok(())
    }
    async fn cancel_commands(&mut self, id: Uuid, reason: &'static str) -> Result<(), String> {
        if self
            .inflight
            .as_ref()
            .is_some_and(|command| command.call_id == id)
        {
            if let Some(execution) = &self.execution {
                execution.cancel();
            }
        }
        let mut retained = VecDeque::new();
        while let Some(command) = self.queue.pop_front() {
            if command.call_id == id && command.action != "hangup" {
                self.completed(&command, Err(reason)).await?;
            } else {
                retained.push_back(command);
            }
        }
        self.queue = retained;
        if let Some(command) = take_waiting_for_call(&mut self.waiting, id) {
            self.completed(&command, Err(reason)).await?;
        }
        if self.journal.call().is_some_and(|call| call.id == id) {
            self.cleanup = Some(reason);
        }
        Ok(())
    }
    async fn close_peers(&mut self) {
        for (_, peer) in self.peers.drain() { peer.close().await; }
    }
    async fn tick(&mut self) -> Result<(), String> {
        self.recovery.call(self.journal.call().is_some() || self.inflight.is_some()
            || self.waiting.is_some() || !self.queue.is_empty())?;
        let now = self.manager.unix_time()?;
        let expired: Vec<_> = self.peers.iter().filter(|(_, peer)| peer.expires_at <= now || matches!(peer.peer.connection_state(),
            webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState::Failed |
            webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState::Closed)).map(|(id, _)| *id).collect();
        for id in expired { self.peers.remove(&id).unwrap().close().await; }
        if self.connected && self.paired && Instant::now() >= self.next_sms {
            self.next_sms = Instant::now() + Duration::from_secs(5);
            match self.state.sms_notifications.pending() {
                Ok(events) => for event in events { self.send(event.message()).await?; },
                Err(code) => { eprintln!("[sms-notifications] {code}"); self.next_sms = Instant::now() + Duration::from_secs(60); },
            }
        }
        if self.cleanup.is_some() {
            if let Some(execution) = &self.execution {
                execution.cancel();
            }
        }
        if let Some(receiver) = self.work.as_mut() {
            match receiver.try_recv() {
                Ok(work) => {
                    self.work = None;
                    self.execution = None;
                    self.inflight = None;
                    self.work_done(work).await?;
                }
                Err(oneshot::error::TryRecvError::Empty) => {}
                Err(oneshot::error::TryRecvError::Closed) => {
                    return Err("modem_worker_stopped".into())
                }
            }
        }
        if self.work.is_some() {
            return Ok(());
        }
        if let Some(reason) = self.cleanup {
            if let Some((command, _)) = self.waiting.take() {
                self.completed(&command, Err(reason)).await?;
            }
            if let Some(media) = self.media.take() {
                media.close().await;
            }
            if self.physical_direction.is_some() {
                let state = self.state.clone();
                let id = self.physical_id;
                let direction = self.physical_direction.clone();
                let number = self.journal.call().and_then(|call| call.number);
                let (tx, rx) = oneshot::channel();
                self.work = Some(rx);
                tokio::task::spawn_blocking(move || {
                    let outcome =
                        cleanup_modem(&state, id, direction.as_deref(), number.as_deref());
                    let _ = tx.send(Work::Cleanup(outcome));
                });
            } else {
                self.finish(reason).await?;
            }
            return Ok(());
        }
        if let Some(command) = self.queue.pop_front() {
            if command.action != "hangup" && self.remaining(&command).is_err() {
                if matches!(command.action.as_str(), "dial" | "answer")
                    && self
                        .journal
                        .call()
                        .is_some_and(|call| call.id == command.call_id)
                {
                    self.cleanup = Some("operation_expired");
                }
                self.completed(&command, Err("operation_expired")).await?;
                return Ok(());
            }
            if command.action == "hangup" {
                if let Some(pending) = take_waiting_for_call(&mut self.waiting, command.call_id) {
                    self.completed(&pending, Err("call_cancelled")).await?;
                }
            }
            let current = self.journal.call();
            let outcome = match command.action.as_str() {
                "dial" => {
                    if current.is_some() {
                        Err("call_in_progress")
                    } else if let Err(error) = audio::available() {
                        Err(error)
                    } else {
                        let line = capture_line(self.state.clone()).await?;
                        self.journal
                            .start(command.call_id, "dialing", command.number.clone(), line)?;
                        self.record_phone(&command);
                        self.call_started = Instant::now();
                        self.modem_seen = false;
                        self.modem_active = false;
                        self.state.call_active.store(true, Ordering::Relaxed);
                        match self.new_media(command.call_id).await {
                            Ok(()) => {
                                self.waiting = Some((command.clone(), Instant::now()));
                                Ok(false)
                            }
                            Err(_) => {
                                self.cleanup = Some("media_prepare_failed");
                                Err("media_prepare_failed")
                            }
                        }
                    }
                }
                "answer" => {
                    if current
                        .as_ref()
                        .is_none_or(|c| c.id != command.call_id || c.state != "ringing")
                    {
                        Err("call_not_ringing")
                    } else if let Err(error) = audio::available() {
                        Err(error)
                    } else {
                        self.record_phone(&command);
                        if self.media.is_none() && self.new_media(command.call_id).await.is_err() {
                            self.completed(&command, Err("media_prepare_failed"))
                                .await?;
                            self.cleanup = Some("media_prepare_failed");
                            return Ok(());
                        }
                        self.waiting = Some((command.clone(), Instant::now()));
                        Ok(false)
                    }
                }
                "hangup" => {
                    if current.as_ref().is_none_or(|c| c.id != command.call_id) {
                        Ok(true)
                    } else {
                        self.cleanup = Some("local_hangup");
                        self.queue.push_front(command);
                        return Ok(());
                    }
                }
                "dtmf" => {
                    if current.as_ref().is_some_and(|c| {
                        c.id == command.call_id && c.state == "active" && c.media_ready
                    }) {
                        self.execute(command.clone()).map(|()| false)
                    } else {
                        Err("call_not_active")
                    }
                }
                _ => Err("invalid_command"),
            };
            match outcome {
                Ok(true) => self.completed(&command, Ok(())).await?,
                Ok(false) => {}
                Err(error) => self.completed(&command, Err(error)).await?,
            }
            self.status(None);
            return Ok(());
        }
        if let Some((command, started)) = &self.waiting {
            if started.elapsed() > Duration::from_secs(12) {
                let command = command.clone();
                self.waiting = None;
                self.completed(&command, Err("media_connection_timeout"))
                    .await?;
                self.cleanup = Some("media_connection_timeout");
                return Ok(());
            }
            if self.media.as_ref().is_some_and(Media::is_connected) {
                let command = command.clone();
                self.waiting = None;
                if let Err(error) = self.execute(command.clone()) {
                    self.completed(&command, Err(error)).await?;
                    self.cleanup = Some(error);
                }
                return Ok(());
            }
        }
        if let Some(call) = self.journal.call() {
            if let Some(media) = self.media.as_mut() {
                if self.modem_active && media.is_connected() && call.state != "ringing" {
                    if let Err(error) = media.start_audio(&self.manager.recordings) {
                        self.cleanup = Some(error);
                        return Ok(());
                    }
                }
                if media.audio_ready() && (!call.media_ready || call.state != "active") {
                    self.event("active", true, None).await?;
                }
            }
            if call.state == "dialing" && self.call_started.elapsed() > Duration::from_secs(60) {
                self.cleanup = Some("no_answer");
            }
        }
        if Instant::now() >= self.next_poll {
            self.next_poll = Instant::now() + Duration::from_secs(2);
            let state = self.state.clone();
            let (tx, rx) = oneshot::channel();
            self.work = Some(rx);
            tokio::task::spawn_blocking(move || {
                let _ = tx.send(Work::Status(read_calls(&state)));
            });
        }
        Ok(())
    }
    fn remaining(&self, command: &Command) -> Result<Duration, &'static str> {
        let admitted = *self
            .admitted
            .get(&command.request_id)
            .ok_or("command_admission_missing")?;
        remaining_window(command, admitted, Instant::now(), self.manager.unix_time()?)
    }
    fn execute(&mut self, command: Command) -> Result<(), &'static str> {
        let remaining = self.remaining(&command)?;
        let execution = Execution::new(remaining);
        let cancelled = execution.cancelled.clone();
        self.execution = Some(execution);
        let state = self.state.clone();
        let expected_line = self.journal.call().and_then(|call| call.line);
        let (tx, rx) = oneshot::channel();
        self.work = Some(rx);
        self.inflight = Some(command.clone());
        tokio::task::spawn_blocking(move || {
            let (outcome, submitted) = execute(&state, &command, &cancelled, expected_line.as_ref());
            let _ = tx.send(Work::Command(command, outcome, submitted));
        });
        Ok(())
    }
    async fn work_done(&mut self, work: Work) -> Result<(), String> {
        match work {
            Work::Cleanup(outcome) => {
                if let Err(error) = outcome {
                    self.status(Some(error));
                    return Err(error.into());
                }
                let reason = self.cleanup.ok_or("cleanup_reason_missing")?;
                self.finish(reason).await?;
            }
            Work::Command(command, outcome, submitted) => {
                if submitted && command.action == "dial" {
                    self.physical_direction = Some("mo".into());
                }
                self.completed(&command, outcome).await?;
                if outcome.is_err() && command.action != "dtmf" {
                    self.cleanup = Some("modem_command_failed");
                }
                if outcome.is_ok() && command.action == "answer" {
                    self.event("answering", false, None).await?;
                }
                if outcome.is_ok() && command.action == "dial" {
                    self.call_started = Instant::now();
                    self.physical_direction = Some("mo".into());
                }
                self.next_poll = Instant::now();
            }
            Work::Status(Err(error)) => self.status(Some(error)),
            Work::Status(Ok(calls)) => {
                if calls.len() > 1 {
                    self.status(Some("multiple_calls_unsupported"));
                    return Ok(());
                }
                if calls.is_empty() {
                    if let Some(call) = self.journal.call() {
                        if self.modem_seen
                            || call.state == "ringing"
                            || (self.waiting.is_none()
                                && self.call_started.elapsed() > Duration::from_secs(10))
                        {
                            self.finish("remote_hangup").await?;
                        }
                    } else {
                        self.state.call_active.store(false, Ordering::Relaxed);
                        self.status(None);
                    }
                    return Ok(());
                }
                let physical = &calls[0];
                let id = physical["id"]
                    .as_i64()
                    .filter(|id| *id >= 0)
                    .ok_or("invalid_modem_call_id")?;
                let state = physical["stat"]
                    .as_str()
                    .ok_or("invalid_modem_call_state")?;
                let direction = physical["dir"]
                    .as_str()
                    .ok_or("invalid_modem_call_direction")?;
                if self.journal.call().is_none() {
                    if self.paired && matches!(state, "incoming" | "waiting") && direction == "mt" {
                        let number = physical["number"]
                            .as_str()
                            .filter(|number| !number.is_empty())
                            .map(String::from);
                        let line = capture_line(self.state.clone()).await?;
                        self.journal.start(Uuid::new_v4(), "ringing", number, line)?;
                        self.modem_seen = true;
                        self.modem_active = false;
                        self.physical_id = Some(id);
                        self.physical_direction = Some(direction.into());
                        self.call_started = Instant::now();
                        self.state.call_active.store(true, Ordering::Relaxed);
                        self.event("ringing", false, None).await?;
                    } else {
                        self.state.call_active.store(true, Ordering::Relaxed);
                        self.status(Some("unmanaged_modem_call"));
                    }
                    return Ok(());
                }
                let call = self.journal.call().ok_or("missing_call")?;
                if !owns_call(
                    physical,
                    self.physical_id,
                    self.physical_direction.as_deref(),
                    call.number.as_deref(),
                ) {
                    self.status(Some("modem_call_identity_changed"));
                    self.finish("modem_call_identity_changed").await?;
                    return Ok(());
                }
                self.physical_id = Some(id);
                self.physical_direction = Some(direction.into());
                self.modem_seen = true;
                self.modem_active = state == "active";
                match state {
                    "active" => {
                        if let Some(media) = self.media.as_mut() {
                            if media.is_connected() {
                                if let Err(error) = media.start_audio(&self.manager.recordings) {
                                    self.cleanup = Some(error);
                                }
                            }
                        } else if self.call_started.elapsed() > Duration::from_secs(15) {
                            self.cleanup = Some("media_unavailable");
                        }
                    }
                    "releasing" => self.finish("remote_hangup").await?,
                    "held" => self.status(Some("call_hold_unsupported")),
                    "dialing" | "alerting" | "incoming" | "waiting" => {}
                    _ => self.status(Some("unknown_modem_call_state")),
                }
            }
        }
        Ok(())
    }
    async fn finish(&mut self, reason: &'static str) -> Result<(), String> {
        self.cleanup = None;
        let recording_id=self.journal.call().map(|call|call.id);
        if let Some((command, _)) = self.waiting.take() {
            self.completed(&command, Err("call_ended")).await?;
        }
        if self.journal.call().is_some() {
            self.event("ended", false, Some(reason)).await?;
            self.journal.finish()?;
        }
        if let Some(media) = self.media.take() {
            media.close().await;
        }
        if let Some(id)=recording_id {self.manager.recordings.stop(id);}
        self.physical_id = None;
        self.physical_direction = None;
        self.modem_seen = false;
        self.modem_active = false;
        while let Some(command) = self.queue.pop_front() {
            self.completed(
                &command,
                if command.action == "hangup" {
                    Ok(())
                } else {
                    Err("call_ended")
                },
            )
            .await?;
        }
        self.status(None);
        Ok(())
    }
    pub async fn shutdown(&mut self) -> Result<(), String> {
        if self.journal.call().is_some() {
            if let Err(code) = self.recovery.notification() { eprintln!("[remote-calling] {code}"); }
        }
        self.close_peers().await;
        *self.manager.local_commands.lock().unwrap() = None;
        if let Some(execution) = &self.execution {
            execution.cancel();
        }
        if let Some(media) = self.media.take() {
            media.close().await;
        }
        // Keep the owner alive until a submitted AT command has returned. Dropping
        // a spawn_blocking receiver does not cancel its modem side effect.
        let mut failure = None;
        if let Some(work) = self.work.take() {
            match tokio::time::timeout(Duration::from_secs(20), work).await {
                Ok(Ok(Work::Command(command, outcome, submitted))) => {
                    if submitted && command.action == "dial" {
                        self.physical_direction = Some("mo".into());
                    }
                    if let Err(error) = self.journal.complete(&command, result(&command, outcome)) {
                        failure = Some(error);
                    }
                }
                Ok(Ok(Work::Cleanup(Ok(())))) => {
                    self.physical_id = None;
                    self.physical_direction = None;
                }
                Ok(Ok(_)) => {}
                _ => failure = Some("modem_shutdown_reconciliation_failed".into()),
            }
        }
        self.execution = None;
        if self.journal.call().is_some() && self.physical_direction.is_some() {
            let state = self.state.clone();
            let id = self.physical_id;
            let direction = self.physical_direction.clone();
            let number = self.journal.call().and_then(|call| call.number);
            match tokio::task::spawn_blocking(move || {
                cleanup_modem(&state, id, direction.as_deref(), number.as_deref())
            })
            .await
            {
                Ok(Ok(())) => {}
                _ => failure = Some("shutdown_call_cleanup_failed".into()),
            }
        }
        if let Some(task) = self.network.take() {
            task.abort();
            let _ = task.await;
        }
        self.manager.set_status(false, failure.as_deref(), None);
        self.recovery.call(false)?;
        match failure {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
}

fn take_waiting_for_call(waiting: &mut Option<(Command, Instant)>, id: Uuid) -> Option<Command> {
    if waiting
        .as_ref()
        .is_some_and(|(command, _)| command.call_id == id)
    {
        waiting.take().map(|(command, _)| command)
    } else {
        None
    }
}

fn remaining_window(
    command: &Command,
    admitted: Instant,
    now: Instant,
    wall_now: u64,
) -> Result<Duration, &'static str> {
    let elapsed = now.saturating_duration_since(admitted);
    let window = Duration::from_secs(20)
        .checked_sub(elapsed)
        .filter(|value| !value.is_zero())
        .ok_or("operation_expired")?;
    Ok(command.remaining(wall_now)?.min(window))
}

fn terminal_ok(response: &str) -> bool {
    response
        .lines()
        .filter(|line| !line.trim().is_empty())
        .last()
        .is_some_and(|line| line.trim() == "OK")
}
fn read_calls(state: &AppState) -> Result<Vec<Value>, &'static str> {
    let raw = at_cmd::send_cancellable(&state.at_port, "AT+CLCC", 2, &AtomicBool::new(false))
        .map_err(|_| "modem_status_unavailable")?;
    let parsed = parse_status(&raw);
    if parsed.is_err() {
        eprintln!("[calling-status] bytes={} lines={} ok={} error={} last_blank={}",raw.len(),raw.lines().count(),raw.lines().any(|line|line.trim()=="OK"),raw.lines().any(|line|line.trim()=="ERROR"),raw.lines().last().is_some_and(|line|line.trim().is_empty()));
    }
    parsed
}
fn parse_status(raw: &str) -> Result<Vec<Value>, &'static str> {
    if !terminal_ok(raw) {
        return Err("modem_status_incomplete");
    }
    let calls = telephony::parse_clcc(raw);
    if raw
        .lines()
        .filter(|line| line.trim_start().starts_with("+CLCC"))
        .count()
        != calls.len()
        || calls.iter().any(|call| {
            call["id"].as_i64().is_none_or(|id| id < 0)
                || !matches!(call["dir"].as_str(), Some("mo" | "mt"))
                || !matches!(
                    call["stat"].as_str(),
                    Some(
                        "active"
                            | "held"
                            | "dialing"
                            | "alerting"
                            | "incoming"
                            | "waiting"
                            | "releasing"
                    )
                )
        })
    {
        return Err("invalid_modem_status");
    }
    // CLCC on this modem also lists its cellular data sessions. Pure data/fax
    // entries must not block a voice dial or become an incoming phone call.
    Ok(calls.into_iter().filter(|call| !matches!(call["mode"].as_i64(),Some(1|2))).collect())
}
async fn capture_line(state: Arc<AppState>) -> Result<Option<crate::cellular_line::CellularLine>, String> {
    tokio::task::spawn_blocking(move || match crate::sim::capture_line(&state) {
        Ok(line) => Some(line),
        Err(error) => { eprintln!("[call-line] {error}"); None }
    }).await.map_err(|_| "call_line_worker_stopped".into())
}

fn execute(
    state: &AppState,
    command: &Command,
    cancelled: &AtomicBool,
    expected_line: Option<&crate::cellular_line::CellularLine>,
) -> (Result<(), &'static str>, bool) {
    let submitted = AtomicBool::new(false);
    let outcome = (|| {
        command.validate()?;
        if cancelled.load(Ordering::Acquire) {
            return Err("command_cancelled");
        }
        let code = match command.action.as_str() {
            "dial" => {
                if let Some(expected) = expected_line {
                    let current = crate::sim::capture_line(state).map_err(|_| "sim_line_unavailable")?;
                    if current.iccid != expected.iccid { return Err("sim_line_changed"); }
                }
                if !read_calls(state)?.is_empty() {
                    return Err("modem_busy");
                }
                format!("ATD{};", command.number.as_deref().ok_or("missing_number")?)
            }
            "answer" => "ATA".into(),
            "dtmf" => format!(
                "AT{}",
                command
                    .digits
                    .as_deref()
                    .ok_or("missing_digits")?
                    .chars()
                    .map(|digit| format!("+VTS={digit}"))
                    .collect::<Vec<_>>()
                    .join(";")
            ),
            _ => return Err("unsupported_modem_operation"),
        };
        if cancelled.load(Ordering::Acquire) {
            return Err("command_cancelled");
        }
        let response =
            at_cmd::send_cancellable_tracked(&state.at_port, &code, 5, cancelled, &submitted)
                .map_err(|_| "modem_command_unavailable")?;
        if !terminal_ok(&response) {
            return Err("modem_rejected_command");
        }
        if command.action != "dtmf" {
            state.call_active.store(true, Ordering::Relaxed);
        }
        Ok(())
    })();
    (
        outcome,
        command.action == "dial" && submitted.load(Ordering::Acquire),
    )
}
fn owns_call(
    physical: &Value,
    id: Option<i64>,
    direction: Option<&str>,
    number: Option<&str>,
) -> bool {
    if direction.is_none() || physical["dir"].as_str() != direction {
        return false;
    }
    if let Some(id) = id {
        physical["id"].as_i64() == Some(id)
    } else {
        direction == Some("mo") && number.is_some() && physical["number"].as_str() == number
    }
}

fn cleanup_modem(
    state: &AppState,
    id: Option<i64>,
    direction: Option<&str>,
    number: Option<&str>,
) -> Result<(), &'static str> {
    let calls = read_calls(state)?;
    if calls.is_empty() {
        state.call_active.store(false, Ordering::Relaxed);
        return Ok(());
    }
    if calls.len() != 1 || !owns_call(&calls[0], id, direction, number) {
        return Err("modem_call_identity_changed");
    }
    let response = at_cmd::send_cancellable(&state.at_port, "AT+CHUP", 3, &AtomicBool::new(false))
        .map_err(|_| "modem_hangup_unavailable")?;
    if !terminal_ok(&response) {
        return Err("modem_hangup_failed");
    }
    state.call_active.store(false, Ordering::Relaxed);
    Ok(())
}

async fn connection(
    config: Config,
    manager: Arc<RemoteCalling>,
    mut outgoing: mpsc::Receiver<Value>,
    incoming: mpsc::Sender<Network>,
    mut resumed: tokio::sync::watch::Receiver<u64>,
) {
    let mut delay = 1;
    loop {
        let attempt = async {
            // Doors learned since the worker started take part in this attempt's choice.
            let current = manager.current_config().filter(|c| c.server_url == config.server_url).unwrap_or_else(|| config.clone());
            let endpoint = manager.doors.select(&current).await.socket_url("v1/socket");
            let mut request = endpoint.into_client_request().map_err(|_| "invalid_websocket_request")?;
            request.headers_mut().insert("Authorization", format!("Bearer {}", config.device_token).parse().map_err(|_| "invalid_device_token")?);
            let mut limits = WebSocketConfig::default(); limits.max_message_size = Some(98304); limits.max_frame_size = Some(98304);
            let connect = tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async_with_config(request, Some(limits), false)); tokio::pin!(connect);
            let (socket, _) = loop { tokio::select! { result = &mut connect => break result.map_err(|_| "signaling_timeout")?.map_err(|_| "signaling_connect_failed")?, value = outgoing.recv() => { if value.is_none() { return Ok::<(), &'static str>(()); } } } };
            let (mut write, mut read) = socket.split(); delay = 1;
            let mut heartbeat = tokio::time::interval(Duration::from_secs(15));
            let mut last_read = Instant::now();
            loop {
                tokio::select! {
                    input = read.next() => match input {
                        Some(Ok(Message::Text(text))) => { last_read = Instant::now(); let value = serde_json::from_str(&text).map_err(|_| "invalid_server_message")?; incoming.send(Network::Message(value)).await.map_err(|_| "worker_stopped")?; },
                        Some(Ok(Message::Ping(bytes))) => { last_read = Instant::now(); tokio::time::timeout(Duration::from_secs(5), write.send(Message::Pong(bytes))).await.map_err(|_| "signaling_send_timeout")?.map_err(|_| "signaling_send_failed")?; },
                        Some(Ok(Message::Pong(_))) => { last_read = Instant::now(); },
                        _ => return Err("signaling_disconnected"),
                    },
                    value = outgoing.recv() => {
                        let Some(value) = value else { return Ok(()); };
                        tokio::time::timeout(Duration::from_secs(5), write.send(Message::Text(value.to_string().into()))).await.map_err(|_| "signaling_send_timeout")?.map_err(|_| "signaling_send_failed")?;
                    },
                    _ = heartbeat.tick() => { if last_read.elapsed() >= Duration::from_secs(30) { return Err("signaling_liveness_timeout"); } tokio::time::timeout(Duration::from_secs(5), write.send(Message::Text(json!({"type": "ping"}).to_string().into()))).await.map_err(|_| "signaling_send_timeout")?.map_err(|_| "signaling_send_failed")?; }
                }
            }
        };
        let result = until_resume(&mut resumed, attempt).await;
        let (error, reset) = match result {
            Ok(Ok(())) => return,
            Ok(Err(error)) => (error, false),
            Err(()) => ("signaling_resuming", true),
        };
        if incoming.send(Network::Offline(error)).await.is_err() {
            return;
        }
        if reset { delay = 1; continue; }
        let backoff = async {
            let sleep = tokio::time::sleep(Duration::from_secs(delay));
            tokio::pin!(sleep);
            loop {
                tokio::select! { _ = &mut sleep => return true, value = outgoing.recv() => if value.is_none() { return false; } }
            }
        };
        match until_resume(&mut resumed, backoff).await {
            Ok(false) => return,
            Ok(true) => delay = (delay * 2).min(30),
            Err(()) => delay = 1,
        }
    }
}


// Cancelling this future drops the stale socket or its backoff timer. The call
// owner and durable journals live outside it and survive the transport reset.
async fn until_resume<T>(resumed: &mut tokio::sync::watch::Receiver<u64>, work: impl std::future::Future<Output = T>) -> Result<T, ()> {
    tokio::select! {
        biased;
        changed = resumed.changed() => { changed.expect("wake recovery owner outlives signaling"); Err(()) },
        value = work => Ok(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn resume_cancels_a_stale_socket_or_backoff_without_waiting_for_its_timeout() {
        for connecting in [true, false] {
            let (wake, mut resumed) = tokio::sync::watch::channel(0);
            let dropped = Arc::new(AtomicBool::new(false));
            struct Pending(Arc<AtomicBool>);
            impl Drop for Pending { fn drop(&mut self) { self.0.store(true, Ordering::Release); } }
            let marker = Pending(dropped.clone());
            let (entered, started) = oneshot::channel();
            let work = async move {
                let _marker = marker;
                entered.send(()).unwrap();
                if connecting { std::future::pending::<()>().await; }
                else { tokio::time::sleep(Duration::from_secs(30)).await; }
            };
            let owner = tokio::spawn(async move {
                let outcome = until_resume(&mut resumed, work).await;
                (outcome, resumed)
            });
            started.await.unwrap();
            wake.send_replace(1);
            let (outcome, mut resumed) = tokio::time::timeout(Duration::from_secs(1), owner).await.unwrap().unwrap();
            assert_eq!(outcome, Err(()));
            assert!(dropped.load(Ordering::Acquire));
            // The new connection proceeds after consuming this generation.
            assert_eq!(until_resume(&mut resumed, async { 42 }).await, Ok(42));
        }
    }
    #[test]
    fn cancellation_preserves_a_different_call_waiting_for_media() {
        let id = Uuid::new_v4();
        let request_id = Uuid::new_v4();
        let command = Command {
            kind: "command".into(),
            request_id,
            call_id: id,
            action: "answer".into(),
            expires_at: 1000,
            number: None,
            digits: None,
            phone: None,
        };
        let mut waiting = Some((command, Instant::now()));
        assert!(take_waiting_for_call(&mut waiting, Uuid::new_v4()).is_none());
        assert_eq!(waiting.as_ref().unwrap().0.request_id, request_id);
        assert_eq!(
            take_waiting_for_call(&mut waiting, id).unwrap().request_id,
            request_id
        );
        assert!(waiting.is_none());
    }
    #[test]
    fn media_setup_and_queue_wait_cannot_restart_the_command_deadline() {
        let command = Command {
            kind: "command".into(),
            request_id: Uuid::new_v4(),
            call_id: Uuid::new_v4(),
            action: "dial".into(),
            expires_at: 1000,
            number: Some("123".into()),
            digits: None,
            phone: None,
        };
        let admitted = Instant::now();
        assert_eq!(
            remaining_window(&command, admitted, admitted + Duration::from_secs(19), 100).unwrap(),
            Duration::from_secs(1)
        );
        assert!(
            remaining_window(&command, admitted, admitted + Duration::from_secs(20), 100).is_err()
        );
        assert!(remaining_window(&command, admitted, admitted, 1000).is_err());
    }
    #[tokio::test]
    async fn execution_cancellation_is_durable_until_the_port_can_be_acquired() {
        let execution = Execution::new(Duration::from_millis(20));
        let marker = execution.cancelled.clone();
        tokio::time::timeout(Duration::from_secs(1), async {
            while !marker.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(marker.load(Ordering::Acquire));
        let execution = Execution::new(Duration::from_secs(30));
        let marker = execution.cancelled.clone();
        drop(execution);
        assert!(marker.load(Ordering::Acquire));
    }
    #[test]
    fn cleanup_requires_a_submitted_dial_or_the_original_modem_identity() {
        let physical = json!({"id":2,"dir":"mo","number":"12345"});
        assert!(!owns_call(&physical, None, None, Some("12345")));
        assert!(owns_call(&physical, None, Some("mo"), Some("12345")));
        assert!(!owns_call(&physical, None, Some("mo"), Some("99999")));
        assert!(!owns_call(&physical, Some(3), Some("mo"), Some("12345")));
        assert!(!owns_call(&physical, Some(2), Some("mt"), Some("12345")));
        assert!(owns_call(&physical, Some(2), Some("mo"), None));
    }
    #[test]
    fn an_incomplete_or_malformed_modem_snapshot_never_proves_idle() {
        for raw in [
            "",
            "ERROR",
            "+CLCC: 1,0,0,0,0",
            "+CLCC: truncated\r\nOK",
            "+CLCC truncated\r\nOK",
            "+CLCC: 1,x,0,0,0\r\nOK",
        ] {
            assert!(parse_status(raw).is_err(), "{raw}");
        }
        assert!(parse_status("AT+CLCC\r\n\r\nOK\r\n").unwrap().is_empty());
        assert!(parse_status("\r\n+CLCC: 1,1,0,1,0\r\n+CLCC: 2,1,0,2,0\r\nOK\r\n\r\n").unwrap().is_empty());
        let mixed=parse_status("+CLCC: 1,1,0,1,0\r\n+CLCC: 3,0,2,0,0,\"123\",129\r\nOK\r\n\r\n").unwrap();
        assert_eq!(mixed.len(),1);
        assert_eq!(mixed[0]["id"],3);
        assert_eq!(
            parse_status("+CLCC: 2,1,4,0,0,\"123\",129\r\nOK").unwrap()[0]["id"],
            2
        );
    }
}
