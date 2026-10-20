use super::{
    audio,
    journal::{result, Begin, Command, Journal},
    media::Media,
    Config, RemoteCalling,
};
use crate::{at_cmd, handlers::AppState, telephony};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::VecDeque;
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
pub struct Worker {
    state: Arc<AppState>,
    manager: Arc<RemoteCalling>,
    config: Config,
    journal: Journal,
    media: Option<Media>,
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
    cancelled: Arc<AtomicBool>,
    work: Option<oneshot::Receiver<Work>>,
    next_poll: Instant,
    call_started: Instant,
    cleanup: Option<&'static str>,
    modem_seen: bool,
    modem_active: bool,
    physical_id: Option<i64>,
    physical_direction: Option<String>,
}
impl Worker {
    pub fn new(
        state: Arc<AppState>,
        manager: Arc<RemoteCalling>,
        config: Config,
    ) -> Result<Self, String> {
        let journal = Journal::open(std::path::Path::new(super::JOURNAL))?;
        let (signals, outgoing) = mpsc::channel(64);
        let (failures, failure_rx) = mpsc::channel(8);
        Ok(Self {
            state,
            manager,
            config,
            journal,
            media: None,
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
            cancelled: Arc::new(AtomicBool::new(false)),
            work: None,
            next_poll: Instant::now(),
            call_started: Instant::now(),
            cleanup: None,
            modem_seen: false,
            modem_active: false,
            physical_id: None,
            physical_direction: None,
        })
    }
    pub async fn run(&mut self) -> Result<(), String> {
        let (events, mut incoming) = mpsc::channel(64);
        let config = self.config.clone();
        let outgoing = self.outgoing.take().ok_or("network_already_started")?;
        self.network = Some(tokio::spawn(connection(config, outgoing, events)));
        // A modem ID may be reused while the agent is stopped. Do not redial or
        // hang up an unidentified physical call when recovering an old session.
        if self.journal.call().is_some() {
            self.journal
                .event("ended", false, Some("agent_restarted"))?;
            self.journal.finish()?;
        }
        let mut tick = tokio::time::interval(Duration::from_millis(100));
        loop {
            tokio::select! {
                _ = self.manager.changed.notified() => return Ok(()),
                message = incoming.recv() => match message.ok_or("network_worker_stopped")? {
                    Network::Offline(error) => { self.connected = false; self.status(Some(error)); },
                    Network::Message(value) => self.message(value).await?,
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
    async fn event(
        &mut self,
        state: &str,
        media: bool,
        reason: Option<&str>,
    ) -> Result<(), String> {
        let event = self.journal.event(state, media, reason)?;
        self.send(event).await?;
        self.status(reason);
        Ok(())
    }
    async fn completed(
        &mut self,
        command: &Command,
        outcome: Result<(), &str>,
    ) -> Result<(), String> {
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
            "hello" => {
                if value["protocol"] != 1
                    || value["role"] != "router"
                    || value["endpointId"].as_str()
                        != self.config.endpoint_id.map(|id| id.to_string()).as_deref()
                {
                    return Err("invalid_server_identity".into());
                }
                self.ice = serde_json::from_value(value["iceServers"].clone())
                    .map_err(|_| "invalid_ice_servers")?;
                self.connected = true;
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
            "call" => {
                if value["state"] == "ended"
                    && self.journal.call().is_some_and(|call| {
                        value["callId"].as_str() == Some(call.id.to_string().as_str())
                    })
                {
                    self.cleanup = Some("session_ended");
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
    async fn tick(&mut self) -> Result<(), String> {
        if let Some(receiver) = self.work.as_mut() {
            match receiver.try_recv() {
                Ok(work) => {
                    self.work = None;
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
            if command.action == "hangup" {
                if let Some((pending, _)) = self.waiting.take() {
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
                        self.journal
                            .start(command.call_id, "dialing", command.number.clone())?;
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
                        self.execute(command.clone());
                        Ok(false)
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
                self.execute(command);
                return Ok(());
            }
        }
        if let Some(call) = self.journal.call() {
            if let Some(media) = self.media.as_mut() {
                if self.modem_active && media.is_connected() && call.state != "ringing" {
                    if let Err(error) = media.start_audio() {
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
    fn execute(&mut self, command: Command) {
        let state = self.state.clone();
        let cancelled = self.cancelled.clone();
        let (tx, rx) = oneshot::channel();
        self.work = Some(rx);
        self.inflight = Some(command.clone());
        tokio::task::spawn_blocking(move || {
            let (outcome, submitted) = execute(&state, &command, &cancelled);
            let _ = tx.send(Work::Command(command, outcome, submitted));
        });
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
                        self.journal.start(Uuid::new_v4(), "ringing", number)?;
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
                                if let Err(error) = media.start_audio() {
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
        self.cancelled.store(true, Ordering::Release);
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
        match failure {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
}

fn terminal_ok(response: &str) -> bool {
    response
        .lines()
        .last()
        .is_some_and(|line| line.trim() == "OK")
}
fn read_calls(state: &AppState) -> Result<Vec<Value>, &'static str> {
    let raw = at_cmd::send_cancellable(&state.at_port, "AT+CLCC", 2, &AtomicBool::new(false))
        .map_err(|_| "modem_status_unavailable")?;
    parse_status(&raw)
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
    Ok(calls)
}
fn execute(
    state: &AppState,
    command: &Command,
    cancelled: &AtomicBool,
) -> (Result<(), &'static str>, bool) {
    let mut submitted = false;
    let outcome = (|| {
        command.validate()?;
        if cancelled.load(Ordering::Acquire) {
            return Err("command_cancelled");
        }
        let code = match command.action.as_str() {
            "dial" => {
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
        submitted = command.action == "dial";
        let response = at_cmd::send_cancellable(&state.at_port, &code, 5, cancelled)
            .map_err(|_| "modem_command_unavailable")?;
        if !terminal_ok(&response) {
            return Err("modem_rejected_command");
        }
        if command.action != "dtmf" {
            state.call_active.store(true, Ordering::Relaxed);
        }
        Ok(())
    })();
    (outcome, submitted)
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
    mut outgoing: mpsc::Receiver<Value>,
    incoming: mpsc::Sender<Network>,
) {
    let mut delay = 1;
    loop {
        let result = async {
            let endpoint = super::url(&config, "v1/socket").map_err(|_| "invalid_server_url")?.replacen("https://", "wss://", 1);
            let mut request = endpoint.into_client_request().map_err(|_| "invalid_websocket_request")?;
            request.headers_mut().insert("Authorization", format!("Bearer {}", config.device_token).parse().map_err(|_| "invalid_device_token")?);
            let mut limits = WebSocketConfig::default(); limits.max_message_size = Some(65536); limits.max_frame_size = Some(65536);
            let connect = tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async_with_config(request, Some(limits), false)); tokio::pin!(connect);
            let (socket, _) = loop { tokio::select! { result = &mut connect => break result.map_err(|_| "signaling_timeout")?.map_err(|_| "signaling_connect_failed")?, value = outgoing.recv() => { if value.is_none() { return Ok::<(), &'static str>(()); } } } };
            let (mut write, mut read) = socket.split(); delay = 1;
            let mut heartbeat = tokio::time::interval(Duration::from_secs(15));
            loop {
                tokio::select! {
                    input = read.next() => match input {
                        Some(Ok(Message::Text(text))) => { let value = serde_json::from_str(&text).map_err(|_| "invalid_server_message")?; incoming.send(Network::Message(value)).await.map_err(|_| "worker_stopped")?; },
                        Some(Ok(Message::Ping(bytes))) => { tokio::time::timeout(Duration::from_secs(5), write.send(Message::Pong(bytes))).await.map_err(|_| "signaling_send_timeout")?.map_err(|_| "signaling_send_failed")?; },
                        Some(Ok(Message::Pong(_))) => {},
                        _ => return Err("signaling_disconnected"),
                    },
                    value = outgoing.recv() => {
                        let Some(value) = value else { return Ok(()); };
                        tokio::time::timeout(Duration::from_secs(5), write.send(Message::Text(value.to_string().into()))).await.map_err(|_| "signaling_send_timeout")?.map_err(|_| "signaling_send_failed")?;
                    },
                    _ = heartbeat.tick() => { tokio::time::timeout(Duration::from_secs(5), write.send(Message::Text(json!({"type": "ping"}).to_string().into()))).await.map_err(|_| "signaling_send_timeout")?.map_err(|_| "signaling_send_failed")?; }
                }
            }
        }.await;
        let error = match result {
            Ok(()) => return,
            Err(error) => error,
        };
        if incoming.send(Network::Offline(error)).await.is_err() {
            return;
        }
        let sleep = tokio::time::sleep(Duration::from_secs(delay));
        tokio::pin!(sleep);
        loop {
            tokio::select! { _ = &mut sleep => break, value = outgoing.recv() => if value.is_none() { return; } }
        }
        delay = (delay * 2).min(30);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        assert_eq!(
            parse_status("+CLCC: 2,1,4,0,0,\"123\",129\r\nOK").unwrap()[0]["id"],
            2
        );
    }
}
