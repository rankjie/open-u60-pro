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
    interceptor_registry::register_default_interceptors, media_engine::MediaEngine, APIBuilder,
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
    pub peer: Arc<RTCPeerConnection>,
    track: Arc<TrackLocalStaticSample>,
    connected: watch::Receiver<RTCPeerConnectionState>,
    inbound: Option<mpsc::Receiver<Vec<u8>>>,
    audio: Option<JoinHandle<()>>,
    tasks: Vec<JoinHandle<()>>,
    audio_ready: watch::Receiver<bool>,
    ready_sender: watch::Sender<bool>,
    failure: mpsc::Sender<Failure>,
    candidates: Vec<RTCIceCandidateInit>,
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
    let api = APIBuilder::new()
        .with_media_engine(engine)
        .with_interceptor_registry(registry)
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
        peer.on_peer_connection_state_change(Box::new(move |state| {
            let sender = connected_sender.clone();
            let failure = callback_failure.clone();
            Box::pin(async move {
                let _ = sender.send(state);
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
        peer.on_track(Box::new(move |track, _, _| {
            let tx = inbound_sender.clone();
            let failure = receiver_failure.clone();
            Box::pin(async move {
                let codec = track.codec();
                if !codec
                    .capability
                    .mime_type
                    .eq_ignore_ascii_case("audio/PCMU")
                    || codec.capability.clock_rate != 8000
                {
                    let _ = failure.send((generation, "unsupported_remote_codec")).await;
                    return;
                }
                let mut sequence = None;
                loop {
                    let packet = match track.read_rtp().await {
                        Ok((packet, _)) => packet,
                        Err(_) => break,
                    };
                    if let Some(previous) = sequence {
                        let distance = packet.header.sequence_number.wrapping_sub(previous);
                        if distance == 0 || distance > 32767 {
                            continue;
                        }
                    }
                    sequence = Some(packet.header.sequence_number);
                    if packet.payload.is_empty() || packet.payload.len() > 1600 {
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
            peer,
            track,
            connected,
            inbound: Some(inbound),
            audio: None,
            tasks: vec![rtcp],
            audio_ready,
            ready_sender,
            failure,
            candidates: Vec::new(),
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
    pub fn audio_ready(&self) -> bool {
        *self.audio_ready.borrow()
    }
    pub fn start_audio(&mut self) -> Result<(), &'static str> {
        if self.audio.is_some() {
            return Ok(());
        }
        let mut bridge = AudioBridge::start()?;
        let mut inbound = self.inbound.take().ok_or("audio_already_started")?;
        while inbound.try_recv().is_ok() {}
        let track = self.audio_track();
        let ready = self.ready_sender.clone();
        let failure = self.failure.clone();
        let generation = self.generation;
        self.audio = Some(tokio::spawn(async move {
            let outcome=async {
                let mut packet=[0;8201];
                let count=tokio::time::timeout(Duration::from_secs(3),bridge.socket.recv(&mut packet)).await.map_err(|_| "audio_adapter_timeout")?.map_err(|_| "audio_socket_receive")?;
                let (kind,format)=audio::parse(&packet[..count])?;
                if kind!=1 || format!=[0x40,0x1f,0,0,1,0,16,0] {return Err("unsupported_audio_format");}
                let mut uplink=Vec::with_capacity(640); let mut downlink=Vec::with_capacity(640);
                let mut last_capture=Instant::now(); let mut last_received=Instant::now(); let mut first=true;
                let mut check=tokio::time::interval(Duration::from_millis(250));
                loop {
                    tokio::select! {
                        count=bridge.socket.recv(&mut packet)=>{
                            let count=count.map_err(|_| "audio_socket_receive")?; let (kind,pcm)=audio::parse(&packet[..count])?;
                            if kind!=2 || pcm.is_empty() || pcm.len()%2!=0 {return Err("invalid_capture_audio");}
                            last_capture=Instant::now(); downlink.extend_from_slice(pcm);
                            while downlink.len()>=320 {
                                let data=downlink.drain(..320).collect::<Vec<_>>().as_chunks::<2>().0.iter().map(|s|codec::encode(i16::from_le_bytes([s[0],s[1]]))).collect::<Vec<_>>();
                                track.write_sample(&Sample {data:data.into(),duration:Duration::from_millis(20),..Default::default()}).await.map_err(|_| "audio_send_failed")?;
                                if first {first=false;let _=ready.send(true);}
                            }
                        }
                        pcm=inbound.recv()=>{
                            let pcm=pcm.ok_or("remote_audio_closed")?;last_received=Instant::now();uplink.extend_from_slice(&pcm);
                            while uplink.len()>=320 {
                                let frame=audio::frame(3,&uplink.drain(..320).collect::<Vec<_>>())?;
                                bridge.socket.send(&frame).await.map_err(|_| "audio_socket_send")?;
                            }
                        }
                        _=check.tick()=>{
                            bridge.check()?;
                            if last_capture.elapsed()>Duration::from_secs(3) {return Err("cellular_audio_timeout");}
                            if last_received.elapsed()>Duration::from_secs(10) {return Err("remote_audio_timeout");}
                        }
                    }
                }
                #[allow(unreachable_code)] Ok::<(),&'static str>(())
            }.await;
            let _ = ready.send(false);
            if let Err(error) = outcome {
                let _ = failure.send((generation, error)).await;
            }
        }));
        Ok(())
    }
    pub async fn close(mut self) {
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

impl Drop for Media {
    fn drop(&mut self) {
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
    async fn real_webrtc_negotiation_delivers_g711_audio() {
        exercise(vec![], false).await;
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
        a.close().await.unwrap();
        b.close().await.unwrap();
    }
}
