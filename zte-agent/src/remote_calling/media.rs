use super::{
    audio::{self, AudioBridge},
    codec,
};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use uuid::Uuid;
use webrtc::api::{
    interceptor_registry::register_default_interceptors, media_engine::MediaEngine,
    setting_engine::SettingEngine, APIBuilder,
};
use webrtc::ice_transport::{ice_candidate::RTCIceCandidateInit, ice_server::RTCIceServer};
use webrtc::interceptor::registry::Registry;
use webrtc::media::Sample;
use webrtc::peer_connection::{
    configuration::RTCConfiguration, peer_connection_state::RTCPeerConnectionState,
    sdp::session_description::RTCSessionDescription, RTCPeerConnection,
};
use webrtc::rtp_transceiver::rtp_codec::{
    RTCRtpCodecCapability, RTCRtpCodecParameters, RTPCodecType,
};
use webrtc::track::track_local::{track_local_static_sample::TrackLocalStaticSample, TrackLocal};

pub type Failure = (Uuid, &'static str);

pub struct Media {
    pub generation: Uuid,
    pub call_id: Uuid,
    /// The phone this connection was negotiated with, when known.
    pub phone: Option<Uuid>,
    pub peer: Arc<RTCPeerConnection>,
    track: Arc<TrackLocalStaticSample>,
    connected: watch::Receiver<RTCPeerConnectionState>,
    inbound: Option<mpsc::Receiver<Vec<u8>>>,
    audio: Option<JoinHandle<()>>,
    ringback: Option<JoinHandle<()>>,
    early: Option<JoinHandle<()>>,
    /// When the network's own audio last reached the phone before pickup.
    early_heard: Arc<std::sync::Mutex<Option<Instant>>>,
    tasks: Vec<JoinHandle<()>>,
    audio_ready: watch::Receiver<bool>,
    ready_sender: watch::Sender<bool>,
    failure: mpsc::Sender<Failure>,
    candidates: Vec<RTCIceCandidateInit>,
    wake: Arc<tokio::sync::Notify>,
}

/// One 20 ms PCMU frame of the CEPT ringback tone: 425 Hz, 1 s on, 4 s off.
fn ringback_frame(frame: u64) -> [u8; 160] {
    let on = frame % 250 < 50;
    std::array::from_fn(|i| {
        let n = (frame * 160 + i as u64) as f64;
        let level = if on { (2.0 * std::f64::consts::PI * 425.0 * n / 8000.0).sin() * 8000.0 } else { 0.0 };
        codec::encode(level as i16)
    })
}

/// A 20 ms capture chunk as PCMU, unless it is silent: a modem path that carries no call
/// returns zeros as fast as it is read.
fn early_frame(pcm: &[u8]) -> Option<[u8; 160]> {
    let samples = pcm.as_chunks::<2>().0;
    if pcm.len() != 320 || samples.iter().all(|sample| *sample == [0, 0]) {
        return None;
    }
    Some(std::array::from_fn(|i| codec::encode(i16::from_le_bytes(samples[i]))))
}

pub fn capability() -> RTCRtpCodecCapability {
    RTCRtpCodecCapability {
        mime_type: "audio/PCMU".into(),
        clock_rate: 8000,
        channels: 1,
        ..Default::default()
    }
}

pub async fn peer(ice_servers: Vec<RTCIceServer>) -> Result<Arc<RTCPeerConnection>, &'static str> {
    peer_config(RTCConfiguration {
        ice_servers,
        ..Default::default()
    })
    .await
}
async fn peer_config(config: RTCConfiguration) -> Result<Arc<RTCPeerConnection>, &'static str> {
    let mut engine = MediaEngine::default();
    engine
        .register_codec(
            RTCRtpCodecParameters {
                capability: capability(),
                payload_type: 0,
                ..Default::default()
            },
            RTPCodecType::Audio,
        )
        .map_err(|_| "codec_registration")?;
    let registry = register_default_interceptors(Registry::new(), &mut engine)
        .map_err(|_| "media_interceptors")?;
    // The router offers, so it picks the path. By default it holds back a working path that
    // isn't a direct host one (500 ms for a public mapping, 1 s for a discovered one and 2 s
    // for a relay) hoping for a better one. Between two carrier NATs only a relay works, so
    // the wait is pure delay; on a shared LAN the host pair answers first and still wins.
    let mut settings = SettingEngine::default();
    settings.set_srflx_acceptance_min_wait(Some(Duration::ZERO));
    settings.set_prflx_acceptance_min_wait(Some(Duration::ZERO));
    settings.set_relay_acceptance_min_wait(Some(Duration::ZERO));
    let api = APIBuilder::new()
        .with_media_engine(engine)
        .with_interceptor_registry(registry)
        .with_setting_engine(settings)
        .build();
    Ok(Arc::new(
        api.new_peer_connection(config)
            .await
            .map_err(|_| "peer_create")?,
    ))
}

impl Media {
    pub async fn new(
        call_id: Uuid,
        ice_servers: Vec<RTCIceServer>,
        signals: mpsc::Sender<Value>,
        failure: mpsc::Sender<Failure>,
        wake: Arc<tokio::sync::Notify>,
    ) -> Result<Self, &'static str> {
        let generation = Uuid::new_v4();
        let peer = peer(ice_servers).await?;
        let track = Arc::new(TrackLocalStaticSample::new(
            capability(),
            "cellular-audio".into(),
            call_id.to_string(),
        ));
        let sender = peer
            .add_track(track.clone() as Arc<dyn TrackLocal + Send + Sync>)
            .await
            .map_err(|_| "audio_track")?;
        let rtcp = tokio::spawn(async move {
            let mut bytes = [0; 1500];
            while sender.read(&mut bytes).await.is_ok() {}
        });
        let (connected_sender, connected) = watch::channel(RTCPeerConnectionState::New);
        let callback_failure = failure.clone();
        let callback_wake = wake.clone();
        peer.on_peer_connection_state_change(Box::new(move |state| {
            let sender = connected_sender.clone();
            let failure = callback_failure.clone();
            let wake = callback_wake.clone();
            Box::pin(async move {
                let _ = sender.send(state);
                wake.notify_one();
                if state == RTCPeerConnectionState::Failed {
                    let _ = failure.send((generation, "media_connection_failed")).await;
                }
            })
        }));
        peer.on_ice_candidate(Box::new(move |candidate| {
            let signals = signals.clone();
            Box::pin(async move {
                if let Some(candidate) = candidate {
                    if let Ok(candidate) = candidate.to_json() {
                        let _ = signals
                            .send(json!({"type":"signal","callId":call_id,"candidate":candidate}))
                            .await;
                    }
                }
            })
        }));
        let (inbound_sender, inbound) = mpsc::channel(8);
        let receiver_failure = failure.clone();
        peer.on_track(Box::new(move |track, receiver, _| {
            let tx = inbound_sender.clone();
            let failure = receiver_failure.clone();
            Box::pin(async move {
                // webrtc 0.17 leaves TrackRemote.codec empty for initial PT 0.
                // Resolve the wire payload through the negotiated receiver map.
                let parameters = receiver.get_parameters().await;
                let payload_type = track.payload_type();
                let supported = parameters.codecs.iter().any(|codec| {
                    codec.payload_type == payload_type
                        && codec.capability.mime_type.eq_ignore_ascii_case("audio/PCMU")
                        && codec.capability.clock_rate == 8000
                });
                if !supported {
                    let _ = failure.send((generation, "unsupported_remote_codec")).await;
                    return;
                }
                let mut sequence = None;
                loop {
                    let packet = match track.read_rtp().await {
                        Ok((packet, _)) => packet,
                        Err(_) => break,
                    };
                    if packet.header.payload_type != payload_type {
                        let _ = failure.send((generation, "unsupported_remote_codec")).await;
                        break;
                    }
                    if let Some(previous) = sequence {
                        let distance = packet.header.sequence_number.wrapping_sub(previous);
                        if distance == 0 || distance > 32767 {
                            continue;
                        }
                    }
                    sequence = Some(packet.header.sequence_number);
                    // WebRTC sends padding/keepalive probes on the audio SSRC.
                    // The RTP reader strips padding; an empty payload has no PCM.
                    if packet.payload.is_empty() {
                        continue;
                    }
                    if packet.payload.len() > 1600 {
                        eprintln!("[calling-media] oversized PCMU payload: {} bytes",packet.payload.len());
                        let _ = failure.send((generation, "invalid_rtp_audio")).await;
                        break;
                    }
                    let mut pcm = Vec::with_capacity(packet.payload.len() * 2);
                    for &byte in packet.payload.iter() {
                        pcm.extend_from_slice(&codec::decode(byte).to_le_bytes());
                    }
                    match tx.try_send(pcm) {
                        Ok(()) => {}
                        Err(mpsc::error::TrySendError::Full(_)) => {} // Live audio has a bounded queue; an obsolete frame is dropped.
                        Err(mpsc::error::TrySendError::Closed(_)) => break,
                    }
                }
            })
        }));
        let (ready_sender, audio_ready) = watch::channel(false);
        Ok(Self {
            generation,
            call_id,
            phone: None,
            peer,
            track,
            connected,
            inbound: Some(inbound),
            audio: None,
            ringback: None,
            early: None,
            early_heard: Arc::new(std::sync::Mutex::new(None)),
            tasks: vec![rtcp],
            audio_ready,
            ready_sender,
            failure,
            candidates: Vec::new(),
            wake,
        })
    }
    pub async fn offer(&self, signals: &mpsc::Sender<Value>) -> Result<(), &'static str> {
        let offer = self
            .peer
            .create_offer(None)
            .await
            .map_err(|_| "offer_create")?;
        self.peer
            .set_local_description(offer.clone())
            .await
            .map_err(|_| "offer_set")?;
        signals
            .send(json!({"type":"signal","callId":self.call_id,"description":offer}))
            .await
            .map_err(|_| "signaling_closed")
    }
    pub async fn signal(&mut self, value: &Value) -> Result<(), &'static str> {
        if let Some(description) = value.get("description") {
            let description: RTCSessionDescription =
                serde_json::from_value(description.clone()).map_err(|_| "invalid_answer")?;
            self.peer
                .set_remote_description(description)
                .await
                .map_err(|_| "answer_set")?;
            for candidate in self.candidates.drain(..) {
                self.peer
                    .add_ice_candidate(candidate)
                    .await
                    .map_err(|_| "candidate_set")?;
            }
        } else if let Some(candidate) = value.get("candidate") {
            let candidate: RTCIceCandidateInit =
                serde_json::from_value(candidate.clone()).map_err(|_| "invalid_candidate")?;
            if self.peer.remote_description().await.is_none() {
                if self.candidates.len() >= 64 {
                    return Err("too_many_candidates");
                }
                self.candidates.push(candidate);
            } else {
                self.peer
                    .add_ice_candidate(candidate)
                    .await
                    .map_err(|_| "candidate_set")?;
            }
        } else {
            return Err("invalid_media_signal");
        }
        Ok(())
    }
    pub(crate) fn audio_track(&self) -> Arc<TrackLocalStaticSample> { self.track.clone() }
    pub fn is_connected(&self) -> bool {
        *self.connected.borrow() == RTCPeerConnectionState::Connected
    }
    pub fn audio_started(&self) -> bool {
        self.audio.is_some()
    }
    pub fn audio_ready(&self) -> bool {
        *self.audio_ready.borrow()
    }
    /// While the callee's phone rings the modem gives no audio, so the phone hears a ringback
    /// tone generated here until cellular audio replaces it.
    pub fn start_ringback(&mut self) {
        if self.audio.is_some() || self.ringback.is_some() {
            return;
        }
        let (track, heard) = (self.audio_track(), self.early_heard.clone());
        self.ringback = Some(tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(20));
            for frame in 0u64.. {
                tick.tick().await;
                if heard.lock().unwrap().is_some_and(|at| at.elapsed() < Duration::from_millis(200)) {
                    continue;
                }
                let sample = Sample { data: ringback_frame(frame).to_vec().into(), duration: Duration::from_millis(20), ..Default::default() };
                if track.write_sample(&sample).await.is_err() {
                    return;
                }
            }
        }));
    }
    /// Before an outgoing call is answered the modem may carry the network's own audio, such
    /// as an announcement that the number does not exist. A separate helper forwards it until
    /// the call's helper takes over at pickup; ordinary ringing gives none.
    pub fn start_early(&mut self) -> Result<(), &'static str> {
        if self.audio.is_some() || self.early.is_some() {
            return Ok(());
        }
        let mut bridge = AudioBridge::start()?;
        let (track, heard, call_id) = (self.audio_track(), self.early_heard.clone(), self.call_id);
        self.early = Some(tokio::spawn(async move {
            let silence = audio::frame(3, &[0; 320]).expect("silence frame");
            let mut packet = [0; 8201];
            let mut check = tokio::time::interval(Duration::from_millis(250));
            let (mut second, mut sent, mut first) = (Instant::now(), 0u32, true);
            loop {
                tokio::select! {
                    count = bridge.socket.recv(&mut packet) => {
                        let Ok(count) = count else { return };
                        let Ok((2, pcm)) = audio::parse(&packet[..count]) else { continue };
                        let _ = bridge.socket.send(&silence).await;
                        if second.elapsed() >= Duration::from_secs(1) { (second, sent) = (Instant::now(), 0); }
                        // Real audio comes once per 20 ms; beyond that the path carries no call.
                        let Some(frame) = early_frame(pcm) else { continue };
                        if sent >= 60 { continue; }
                        sent += 1;
                        *heard.lock().unwrap() = Some(Instant::now());
                        if first { first = false; eprintln!("[calling-media] {call_id} network audio before pickup"); }
                        let sample = Sample { data: frame.to_vec().into(), duration: Duration::from_millis(20), ..Default::default() };
                        if track.write_sample(&sample).await.is_err() { return; }
                    }
                    _ = check.tick() => if bridge.check().is_err() { return },
                }
            }
        }));
        Ok(())
    }
    /// Returns once the early helper is gone, so the call's own helper never runs beside it.
    pub async fn stop_early(&mut self) {
        if let Some(task) = self.early.take() {
            task.abort();
            let _ = task.await;
        }
    }
    pub fn stop_ringback(&mut self) {
        if let Some(task) = self.ringback.take() {
            task.abort();
        }
    }
    pub fn start_audio(&mut self, recordings: &Arc<super::recordings::Recordings>) -> Result<(), &'static str> {
        if self.audio.is_some() {
            return Ok(());
        }
        if self.early.is_some() {
            return Err("early_audio_running");
        }
        self.stop_ringback();
        let mut bridge = AudioBridge::start()?;
        let recorder=match recordings.start(self.call_id) {
            Ok(sink)=>Some(sink),
            Err(error)=>{eprintln!("[recordings] recording unavailable: {error}");None}
        };
        let mut inbound = self.inbound.take().ok_or("audio_already_started")?;
        while inbound.try_recv().is_ok() {}
        let track = self.audio_track();
        let ready = self.ready_sender.clone();
        let failure = self.failure.clone();
        let generation = self.generation;
        let (peer, call_id, wake) = (self.peer.clone(), self.call_id, self.wake.clone());
        self.audio = Some(tokio::spawn(async move {
            let outcome=async {
                let mut packet=[0;8201];
                let count=tokio::time::timeout(Duration::from_secs(3),bridge.socket.recv(&mut packet)).await.map_err(|_| "audio_adapter_timeout")?.map_err(|_| "audio_socket_receive")?;
                let (kind,format)=audio::parse(&packet[..count])?;
                if kind!=1 || format!=[0x40,0x1f,0,0,1,0,16,0] {return Err("unsupported_audio_format");}
                eprintln!("[calling-media] {call_id} audio started via {}", route(&peer).await);
                let mut uplink=Vec::with_capacity(640); let mut downlink=Vec::with_capacity(640);
                let mut last_capture=Instant::now(); let mut last_received=Instant::now(); let mut first=true;
                let mut check=tokio::time::interval(Duration::from_millis(250));
                let mut stats=Stats::new();
                loop {
                    tokio::select! {
                        count=bridge.socket.recv(&mut packet)=>{
                            let count=count.map_err(|_| "audio_socket_receive")?;
                            // Capture queued while this loop was held up is late: only the newest
                            // chunks are sent, so a stall never becomes lasting delay for the phone.
                            let (chunks,dropped)=newest_capture(&bridge.socket,packet[..count].to_vec())?;
                            stats.capture_dropped+=dropped;
                            for chunk in &chunks {
                                let (kind,pcm)=audio::parse(chunk)?;
                                if kind!=2 || pcm.is_empty() || pcm.len()%2!=0 {return Err("invalid_capture_audio");}
                                if let Some(recorder)=&recorder {recorder.push(0,pcm);}
                                stats.capture(pcm.len());
                                last_capture=Instant::now(); downlink.extend_from_slice(pcm);
                                while downlink.len()>=320 {
                                    let data=downlink.drain(..320).collect::<Vec<_>>().as_chunks::<2>().0.iter().map(|s|codec::encode(i16::from_le_bytes([s[0],s[1]]))).collect::<Vec<_>>();
                                    let started=Instant::now();
                                    track.write_sample(&Sample {data:data.into(),duration:Duration::from_millis(20),..Default::default()}).await.map_err(|_| "audio_send_failed")?;
                                    stats.sent(started.elapsed());
                                    if first {first=false;let _=ready.send(true);wake.notify_one();}
                                }
                            }
                        }
                        pcm=inbound.recv()=>{
                            let pcm=pcm.ok_or("remote_audio_closed")?;last_received=Instant::now();uplink.extend_from_slice(&pcm);
                            if let Some(recorder)=&recorder {recorder.push(1,&pcm);}
                            stats.uplink+=1;
                            while uplink.len()>=320 {
                                let frame=audio::frame(3,&uplink.drain(..320).collect::<Vec<_>>())?;
                                bridge.socket.send(&frame).await.map_err(|_| "audio_socket_send")?;
                            }
                        }
                        _=check.tick()=>{
                            bridge.check()?;
                            if last_capture.elapsed()>Duration::from_secs(3) {return Err("cellular_audio_timeout");}
                            if last_received.elapsed()>Duration::from_secs(10) {return Err("remote_audio_timeout");}
                            if stats.started.elapsed()>=Duration::from_secs(5) {
                                eprintln!("[calling-media] {call_id} {} via {}", stats.report(), route(&peer).await);
                                stats=Stats::new();
                            }
                        }
                    }
                }
                #[allow(unreachable_code)] Ok::<(),&'static str>(())
            }.await;
            if let Err(error) = outcome { eprintln!("[calling-media] {call_id} audio ended: {error}"); }
            let _ = ready.send(false);
            if let Err(error) = outcome {
                let _ = failure.send((generation, error)).await;
            }
        }));
        Ok(())
    }
    pub async fn close(mut self) {
        self.stop_ringback();
        self.stop_early().await;
        if let Some(task) = self.audio.take() {
            task.abort();
            let _ = task.await;
        }
        for task in self.tasks.drain(..) {
            task.abort();
            let _ = task.await;
        }
        let _ = self.peer.close().await;
    }
}

/// Capture chunks kept when the socket holds a backlog (one chunk is normally 20 ms).
const CAPTURE_KEEP: usize = 3;

/// `first` plus whatever capture is already queued, keeping the newest `CAPTURE_KEEP` chunks;
/// also returns how many were dropped.
fn newest_capture(socket: &tokio::net::UnixDatagram, first: Vec<u8>) -> Result<(std::collections::VecDeque<Vec<u8>>, usize), &'static str> {
    let mut chunks = std::collections::VecDeque::from([first]);
    let mut dropped = 0;
    let mut packet = [0; 8201];
    loop {
        match socket.try_recv(&mut packet) {
            Ok(count) => {
                chunks.push_back(packet[..count].to_vec());
                if chunks.len() > CAPTURE_KEEP {
                    chunks.pop_front();
                    dropped += 1;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok((chunks, dropped)),
            Err(_) => return Err("audio_socket_receive"),
        }
    }
}

/// Per-call audio counters, logged every five seconds so delay can be traced to its stage.
struct Stats {
    started: Instant,
    capture_bytes: usize,
    chunk: (usize, usize),
    capture_dropped: usize,
    frames: usize,
    slowest: Duration,
    uplink: usize,
}
impl Stats {
    fn new() -> Self {
        Stats { started: Instant::now(), capture_bytes: 0, chunk: (usize::MAX, 0), capture_dropped: 0, frames: 0, slowest: Duration::ZERO, uplink: 0 }
    }
    fn capture(&mut self, bytes: usize) {
        self.capture_bytes += bytes;
        self.chunk = (self.chunk.0.min(bytes), self.chunk.1.max(bytes));
    }
    fn sent(&mut self, took: Duration) {
        self.frames += 1;
        self.slowest = self.slowest.max(took);
    }
    fn report(&self) -> String {
        let seconds = self.started.elapsed().as_secs_f64();
        format!(
            "capture {:.0} B/s chunks {}-{} B dropped {} | sent {:.1} frames/s slowest {} ms | phone {:.1} frames/s",
            self.capture_bytes as f64 / seconds, if self.chunk.1 == 0 { 0 } else { self.chunk.0 }, self.chunk.1, self.capture_dropped,
            self.frames as f64 / seconds, self.slowest.as_millis(), self.uplink as f64 / seconds,
        )
    }
}

/// The selected ICE pair, e.g. "Relay/Udp4 udp -> Srflx/Udp4 rtt 41 ms".
async fn route(peer: &RTCPeerConnection) -> String {
    use webrtc::stats::StatsReportType;
    let reports = peer.get_stats().await.reports;
    let pair = reports.values().filter_map(|report| match report {
        StatsReportType::CandidatePair(pair) if pair.nominated => Some(pair),
        _ => None,
    }).max_by_key(|pair| pair.bytes_sent);
    let Some(pair) = pair else { return "no selected pair".into() };
    let describe = |id: &str| match reports.get(id) {
        Some(StatsReportType::LocalCandidate(c) | StatsReportType::RemoteCandidate(c)) =>
            format!("{:?}/{:?} {}", c.candidate_type, c.network_type, c.relay_protocol).trim_end().to_string(),
        _ => "?".into(),
    };
    format!("{} -> {} rtt {:.0} ms", describe(&pair.local_candidate_id), describe(&pair.remote_candidate_id), pair.current_round_trip_time * 1000.0)
}

impl Drop for Media {
    fn drop(&mut self) {
        self.stop_ringback();
        if let Some(task) = self.early.take() {
            task.abort();
        }
        if let Some(task) = self.audio.take() {
            task.abort();
        }
        for task in self.tasks.drain(..) {
            task.abort();
        }
        let peer = self.peer.clone();
        tokio::spawn(async move {
            let _ = peer.close().await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn capture_held_up_behind_a_stall_is_trimmed_to_the_newest_chunks() {
        let (helper, agent) = tokio::net::UnixDatagram::pair().unwrap();
        for index in 0..9u8 {
            helper.send(&[index; 320]).await.unwrap();
        }
        let mut packet = [0; 8201];
        let count = agent.recv(&mut packet).await.unwrap();
        let (chunks, dropped) = newest_capture(&agent, packet[..count].to_vec()).unwrap();
        assert_eq!(chunks.iter().map(|c| c[0]).collect::<Vec<_>>(), vec![6, 7, 8]);
        assert_eq!(dropped, 6);
        // With nothing queued behind it, a chunk is passed on as it is.
        helper.send(&[42; 640]).await.unwrap();
        let count = agent.recv(&mut packet).await.unwrap();
        let (chunks, dropped) = newest_capture(&agent, packet[..count].to_vec()).unwrap();
        assert_eq!((chunks.len(), chunks[0].len(), chunks[0][0], dropped), (1, 640, 42, 0));
    }
    #[tokio::test]
    async fn production_receiver_decodes_pcmu_payload_zero_after_padding() {
        use webrtc::track::track_local::track_local_static_rtp::TrackLocalStaticRTP;
        use webrtc::track::track_local::TrackLocalWriter;
        use webrtc::rtp::{packet::Packet, header::Header};
        let (signals, _signals) = mpsc::channel(64);
        let (failure, mut errors) = mpsc::channel(8);
        let mut media = Media::new(Uuid::new_v4(), vec![], signals, failure, Arc::new(tokio::sync::Notify::new()))
            .await
            .unwrap();
        let remote = peer(vec![]).await.unwrap();
        let microphone = Arc::new(TrackLocalStaticRTP::new(
            capability(),
            "microphone".into(),
            "test".into(),
        ));
        remote
            .add_track(microphone.clone() as Arc<dyn TrackLocal + Send + Sync>)
            .await
            .unwrap();
        let mut gathered = media.peer.gathering_complete_promise().await;
        media
            .peer
            .set_local_description(media.peer.create_offer(None).await.unwrap())
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(10), gathered.recv())
            .await
            .unwrap();
        remote
            .set_remote_description(media.peer.local_description().await.unwrap())
            .await
            .unwrap();
        let mut gathered = remote.gathering_complete_promise().await;
        remote
            .set_local_description(remote.create_answer(None).await.unwrap())
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(10), gathered.recv())
            .await
            .unwrap();
        media
            .peer
            .set_remote_description(remote.local_description().await.unwrap())
            .await
            .unwrap();
        let received = tokio::time::timeout(Duration::from_secs(10), async {
            let mut tick = tokio::time::interval(Duration::from_millis(20));
            let mut sequence = 0u16;
            loop {
                tokio::select! {
                    packet = media.inbound.as_mut().unwrap().recv() => break packet.expect("production PCM receiver closed"),
                    failure = errors.recv() => panic!("production media rejected negotiated PCMU: {failure:?}"),
                    _ = tick.tick() => if remote.connection_state() == RTCPeerConnectionState::Connected {
                        microphone.write_rtp(&Packet {
                            header: Header { version:2, padding:sequence==0, payload_type:0, sequence_number:sequence, timestamp:u32::from(sequence)*160, ..Default::default() },
                            payload: if sequence==0 {vec![]} else {vec![codec::encode(1000);160]}.into(),
                        }).await.unwrap();
                        sequence=sequence.wrapping_add(1);
                    }
                }
            }
        }).await.unwrap();
        assert_eq!(received.len(), 320);
        assert!(received
            .as_chunks::<2>()
            .0
            .iter()
            .all(|sample| i16::from_le_bytes(*sample) == codec::decode(codec::encode(1000))));
        media.close().await;
        remote.close().await.unwrap();
    }
    #[test]
    fn ringback_is_425_hz_one_second_on_four_off() {
        let samples = |frame: u64| ringback_frame(frame).into_iter().map(codec::decode).collect::<Vec<i16>>();
        // On for 50 frames (1 s), silent for the next 200 (4 s), then again.
        for frame in [0, 25, 49, 250, 299] {
            let tone = samples(frame);
            assert_eq!(tone.len(), 160);
            assert!(tone.iter().map(|s| s.unsigned_abs()).max().unwrap() > 4000, "frame {frame} is silent");
        }
        for frame in [50, 150, 249, 300] {
            assert!(samples(frame).iter().all(|s| s.unsigned_abs() < 16), "frame {frame} is not silent");
        }
        // 425 Hz: 850 sign changes in one second of tone.
        let second: Vec<i16> = (0..50).flat_map(samples).collect();
        let crossings = second.windows(2).filter(|pair| (pair[0] < 0) != (pair[1] < 0)).count();
        assert!((845..=855).contains(&crossings), "{crossings} crossings");
    }
    #[test]
    fn only_audible_early_audio_is_forwarded() {
        // A modem path that is not yet carrying a call returns zeros as fast as it is read.
        assert_eq!(early_frame(&[0; 320]), None);
        let mut announcement = [0u8; 320];
        announcement[100..102].copy_from_slice(&1200i16.to_le_bytes());
        let frame = early_frame(&announcement).unwrap();
        assert_eq!(frame[50], codec::encode(1200));
        assert_eq!(frame[0], codec::encode(0));
        assert_eq!(early_frame(&[1; 318]), None, "only whole 20 ms frames are forwarded");
    }
    #[tokio::test]
    async fn ringback_reaches_the_phone_until_audio_starts() {
        let (signals, _signals) = mpsc::channel(64);
        let (failure, _errors) = mpsc::channel(8);
        let mut media = Media::new(Uuid::new_v4(), vec![], signals, failure, Arc::new(tokio::sync::Notify::new()))
            .await
            .unwrap();
        let remote = peer(vec![]).await.unwrap();
        let (heard, mut tone) = mpsc::channel(64);
        remote.on_track(Box::new(move |track, _, _| {
            let heard = heard.clone();
            Box::pin(async move {
                while let Ok((packet, _)) = track.read_rtp().await {
                    if heard.send(packet.payload.to_vec()).await.is_err() { return; }
                }
            })
        }));
        remote
            .add_transceiver_from_kind(webrtc::rtp_transceiver::rtp_codec::RTPCodecType::Audio, None)
            .await
            .unwrap();
        let mut gathered = media.peer.gathering_complete_promise().await;
        media.peer.set_local_description(media.peer.create_offer(None).await.unwrap()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), gathered.recv()).await.unwrap();
        remote.set_remote_description(media.peer.local_description().await.unwrap()).await.unwrap();
        let mut gathered = remote.gathering_complete_promise().await;
        remote.set_local_description(remote.create_answer(None).await.unwrap()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), gathered.recv()).await.unwrap();
        media.peer.set_remote_description(remote.local_description().await.unwrap()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), async {
            while !media.is_connected() { tokio::time::sleep(Duration::from_millis(10)).await; }
        }).await.unwrap();
        media.start_ringback();
        let payload = tokio::time::timeout(Duration::from_secs(5), tone.recv()).await.unwrap().unwrap();
        assert_eq!(payload, ringback_frame(0).to_vec());
        // The network's own audio (an announcement) silences the generated tone while it plays.
        let early = media.early_heard.clone();
        let speaking = tokio::spawn(async move {
            for _ in 0..30 { *early.lock().unwrap() = Some(Instant::now()); tokio::time::sleep(Duration::from_millis(20)).await; }
        });
        tokio::time::sleep(Duration::from_millis(100)).await;
        while tokio::time::timeout(Duration::from_millis(50), tone.recv()).await.is_ok() {}
        assert!(tokio::time::timeout(Duration::from_millis(300), tone.recv()).await.is_err(), "ringback played over the network's audio");
        speaking.await.unwrap();
        let resumed = tokio::time::timeout(Duration::from_secs(2), tone.recv()).await.unwrap().unwrap();
        assert_eq!(resumed.len(), 160, "ringback resumes once the network's audio stops");
        media.stop_ringback();
        while tokio::time::timeout(Duration::from_millis(200), tone.recv()).await.is_ok() {}
        assert!(tokio::time::timeout(Duration::from_millis(300), tone.recv()).await.is_err(), "ringback kept playing");
        media.close().await;
        remote.close().await.unwrap();
    }
    #[tokio::test]
    async fn real_webrtc_negotiation_delivers_g711_audio() {
        exercise(vec![], false).await;
    }

    /// Between two carrier NATs only a relayed pair works. The router offers, so it nominates the
    /// pair; it must do so as soon as the relay answers, not after an acceptance wait.
    #[tokio::test]
    async fn a_working_relay_is_chosen_without_waiting() {
        use webrtc::peer_connection::policy::ice_transport_policy::RTCIceTransportPolicy;
        use webrtc::turn::{auth::{generate_auth_key, AuthHandler}, relay::relay_static::RelayAddressGeneratorStatic,
            server::{config::{ConnConfig, ServerConfig}, Server}};
        struct Key(Vec<u8>);
        impl AuthHandler for Key {
            fn auth_handle(&self, username: &str, _: &str, _: std::net::SocketAddr) -> Result<Vec<u8>, webrtc::turn::Error> {
                if username == "phone" { Ok(self.0.clone()) } else { Err(webrtc::turn::Error::ErrFakeErr) }
            }
        }
        let socket = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let port = socket.local_addr().unwrap().port();
        let server = Server::new(ServerConfig {
            conn_configs: vec![ConnConfig {
                conn: socket,
                relay_addr_generator: Box::new(RelayAddressGeneratorStatic {
                    relay_address: "127.0.0.1".parse().unwrap(),
                    address: "127.0.0.1".into(),
                    net: Arc::new(webrtc::util::vnet::net::Net::new(None)),
                }),
            }],
            realm: "openu60".into(),
            auth_handler: Arc::new(Key(generate_auth_key("phone", "openu60", "secret"))),
            channel_bind_timeout: Duration::from_secs(0),
            alloc_close_notify: None,
        })
        .await
        .unwrap();
        let servers = vec![RTCIceServer {
            urls: vec![format!("turn:127.0.0.1:{port}?transport=udp")],
            username: "phone".into(),
            credential: "secret".into(),
        }];
        let config = || RTCConfiguration {
            ice_servers: servers.clone(),
            ice_transport_policy: RTCIceTransportPolicy::Relay,
            ..Default::default()
        };
        let (a, b) = (peer_config(config()).await.unwrap(), peer_config(config()).await.unwrap());
        let track = Arc::new(TrackLocalStaticSample::new(capability(), "test".into(), "synthetic".into()));
        a.add_track(track as Arc<dyn TrackLocal + Send + Sync>).await.unwrap();
        let mut gathered = a.gathering_complete_promise().await;
        a.set_local_description(a.create_offer(None).await.unwrap()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), gathered.recv()).await.unwrap();
        assert!(a.local_description().await.unwrap().sdp.contains(" typ relay"));
        b.set_remote_description(a.local_description().await.unwrap()).await.unwrap();
        let mut gathered = b.gathering_complete_promise().await;
        b.set_local_description(b.create_answer(None).await.unwrap()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), gathered.recv()).await.unwrap();
        let started = Instant::now();
        a.set_remote_description(b.local_description().await.unwrap()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), async {
            while a.connection_state() != RTCPeerConnectionState::Connected {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        let elapsed = started.elapsed();
        assert!(route(&a).await.starts_with("Relay/"));
        assert!(elapsed < Duration::from_millis(1000), "relay connected after {elapsed:?}");
        a.close().await.unwrap();
        b.close().await.unwrap();
        server.close().await.unwrap();
    }

    fn external_servers(transport: &str) -> Vec<RTCIceServer> {
        let file =
            std::env::var("OPENU60_TURN_TEST_FILE").expect("private TURN credential file required");
        let bytes = super::super::storage::private_read(std::path::Path::new(&file)).unwrap();
        let mut servers: Vec<RTCIceServer> = serde_json::from_slice(&bytes).unwrap();
        for server in &mut servers {
            server
                .urls
                .retain(|url| url.ends_with(&format!("?transport={transport}")));
        }
        servers.retain(|server| !server.urls.is_empty());
        assert!(
            !servers.is_empty(),
            "required TURN transport is not configured"
        );
        servers
    }
    #[tokio::test]
    #[ignore = "requires an explicitly provisioned private TURN credential file"]
    async fn external_turn_relay_delivers_g711_audio() {
        exercise(external_servers("udp"), true).await;
    }

    #[tokio::test]
    #[ignore = "requires an explicitly provisioned private TURN credential file"]
    async fn external_turn_tcp_relay_delivers_g711_audio() {
        exercise(external_servers("tcp"), true).await;
    }

    async fn exercise(ice_servers: Vec<RTCIceServer>, relay: bool) {
        use webrtc::peer_connection::policy::ice_transport_policy::RTCIceTransportPolicy;
        let policy = if relay {
            RTCIceTransportPolicy::Relay
        } else {
            RTCIceTransportPolicy::All
        };
        let a = peer_config(RTCConfiguration {
            ice_servers: ice_servers.clone(),
            ice_transport_policy: policy,
            ..Default::default()
        })
        .await
        .unwrap();
        let b = peer_config(RTCConfiguration {
            ice_servers,
            ice_transport_policy: policy,
            ..Default::default()
        })
        .await
        .unwrap();
        let track = Arc::new(TrackLocalStaticSample::new(
            capability(),
            "test".into(),
            "synthetic".into(),
        ));
        a.add_track(track.clone() as Arc<dyn TrackLocal + Send + Sync>)
            .await
            .unwrap();
        let reverse = Arc::new(TrackLocalStaticSample::new(
            capability(),
            "reverse".into(),
            "synthetic".into(),
        ));
        b.add_track(reverse.clone() as Arc<dyn TrackLocal + Send + Sync>)
            .await
            .unwrap();
        let (tx_reverse, mut rx_reverse) = mpsc::channel(1);
        a.on_track(Box::new(move |track, _, _| {
            let tx = tx_reverse.clone();
            Box::pin(async move {
                let (packet, _) = track.read_rtp().await.unwrap();
                tx.send(packet.payload.to_vec()).await.unwrap();
            })
        }));
        let (tx, mut rx) = mpsc::channel(1);
        b.on_track(Box::new(move |track, _, _| {
            let tx = tx.clone();
            Box::pin(async move {
                let (packet, _) = track.read_rtp().await.unwrap();
                tx.send(packet.payload.to_vec()).await.unwrap();
            })
        }));
        let mut gathered = a.gathering_complete_promise().await;
        a.set_local_description(a.create_offer(None).await.unwrap())
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(20), gathered.recv())
            .await
            .unwrap();
        if relay {
            assert!(
                a.local_description()
                    .await
                    .unwrap()
                    .sdp
                    .contains(" typ relay"),
                "TURN allocation did not produce a relay candidate"
            );
        }
        b.set_remote_description(a.local_description().await.unwrap())
            .await
            .unwrap();
        let mut gathered = b.gathering_complete_promise().await;
        b.set_local_description(b.create_answer(None).await.unwrap())
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(20), gathered.recv())
            .await
            .unwrap();
        if relay {
            assert!(
                b.local_description()
                    .await
                    .unwrap()
                    .sdp
                    .contains(" typ relay"),
                "TURN allocation did not produce a relay candidate"
            );
        }
        a.set_remote_description(b.local_description().await.unwrap())
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            while a.connection_state() != RTCPeerConnectionState::Connected {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let payload = vec![codec::encode(1000); 160];
        track
            .write_sample(&Sample {
                data: payload.clone().into(),
                duration: Duration::from_millis(20),
                ..Default::default()
            })
            .await
            .unwrap();
        let received = tokio::time::timeout(Duration::from_secs(5), rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(received, payload);
        let payload = vec![codec::encode(-2000); 160];
        reverse
            .write_sample(&Sample {
                data: payload.clone().into(),
                duration: Duration::from_millis(20),
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), rx_reverse.recv())
                .await
                .unwrap()
                .unwrap(),
            payload
        );
        // The logged path names the pair actually carrying audio.
        let path = route(&a).await;
        let expected = if relay { "Relay/" } else { "Host/" };
        assert!(path.starts_with(expected) && path.contains(" -> ") && path.ends_with(" ms"), "{path}");
        a.close().await.unwrap();
        b.close().await.unwrap();
    }
}
