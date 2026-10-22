use crate::handlers::AppState;
use base64::Engine;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, Semaphore};
use uuid::Uuid;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice_transport::{ice_candidate::RTCIceCandidateInit, ice_server::RTCIceServer};
use webrtc::peer_connection::{sdp::session_description::RTCSessionDescription, RTCPeerConnection};

const CHUNK: usize = 12288;
const HEADER: usize = 25;
const REQUEST_LIMIT: usize = 98304;
const MESSAGE_LIMIT: usize = 786432;

pub fn ice_servers(value: &Value) -> Result<Vec<RTCIceServer>, &'static str> {
    let servers: Vec<RTCIceServer> = serde_json::from_value(value.clone()).map_err(|_| "invalid_peer_ice")?;
    if servers.len() > 4 || servers.iter().any(|server| server.urls.len() > 4 || server.urls.iter().any(|url| !url.starts_with("stun:"))) {
        return Err("invalid_peer_ice");
    }
    Ok(servers)
}

struct Partial { total: usize, data: Vec<u8>, since: Instant }
#[derive(Default)]
struct Frames { partial: HashMap<Uuid, Partial> }
impl Frames {
    fn receive(&mut self, frame: &[u8], limit: usize) -> Result<Option<(Uuid, Vec<u8>)>, &'static str> {
        self.partial.retain(|_, value| value.since.elapsed() < Duration::from_secs(10));
        if frame.len() <= HEADER || frame.len() > HEADER + CHUNK || frame[0] != 1 { return Err("invalid_peer_frame"); }
        let id = Uuid::from_slice(&frame[1..17]).map_err(|_| "invalid_peer_frame")?;
        let total = u32::from_be_bytes(frame[17..21].try_into().unwrap()) as usize;
        let offset = u32::from_be_bytes(frame[21..25].try_into().unwrap()) as usize;
        if total == 0 || total > limit || offset + frame.len() - HEADER > total { return Err("invalid_peer_frame"); }
        if !self.partial.contains_key(&id) {
            if offset != 0 || self.partial.len() >= 8 { return Err("peer_frame_capacity"); }
            self.partial.insert(id, Partial { total, data: Vec::with_capacity(total), since: Instant::now() });
        }
        let value = self.partial.get_mut(&id).unwrap();
        if value.total != total || value.data.len() != offset { return Err("invalid_peer_frame_order"); }
        value.data.extend_from_slice(&frame[HEADER..]);
        if value.data.len() == total { return Ok(Some((id, self.partial.remove(&id).unwrap().data))); }
        Ok(None)
    }
}
fn frames(id: Uuid, data: &[u8]) -> Result<Vec<Vec<u8>>, &'static str> {
    if data.is_empty() || data.len() > MESSAGE_LIMIT { return Err("peer_message_too_large"); }
    Ok(data.chunks(CHUNK).enumerate().map(|(index, bytes)| {
        let mut frame = Vec::with_capacity(HEADER + bytes.len());
        frame.push(1); frame.extend_from_slice(id.as_bytes());
        frame.extend_from_slice(&(data.len() as u32).to_be_bytes());
        frame.extend_from_slice(&((index * CHUNK) as u32).to_be_bytes());
        frame.extend_from_slice(bytes); frame
    }).collect())
}
async fn send(channel: &RTCDataChannel, id: Uuid, value: Value) -> Result<(), &'static str> {
    let data = serde_json::to_vec(&value).map_err(|_| "invalid_peer_message")?;
    for frame in frames(id, &data)? {
        tokio::time::timeout(Duration::from_secs(3), channel.send(&frame.into())).await
            .map_err(|_| "peer_send_timeout")?.map_err(|_| "peer_send_failed")?;
    }
    Ok(())
}

pub struct Peer {
    pub peer: Arc<RTCPeerConnection>,
    pub expires_at: u64,
    valid: Arc<AtomicBool>,
    channel: Arc<RTCDataChannel>,
    candidates: Vec<RTCIceCandidateInit>,
}
impl Peer {
    pub async fn new(id: Uuid, router: Uuid, phone: Uuid, expires_at: u64, ice: Vec<RTCIceServer>,
        state: Arc<AppState>, signals: mpsc::Sender<Value>) -> Result<Self, &'static str> {
        // No audio tracks: management is available without a call or microphone permission.
        let peer = Arc::new(webrtc::api::APIBuilder::new().build().new_peer_connection(
            webrtc::peer_connection::configuration::RTCConfiguration { ice_servers: ice, ..Default::default() }
        ).await.map_err(|_| "peer_create_failed")?);
        let channel = peer.create_data_channel("openu60-management-v1", None).await.map_err(|_| "peer_channel_failed")?;
        let valid = Arc::new(AtomicBool::new(true));
        let receive_channel = channel.clone(); let receive_valid = valid.clone();
        let receiver = Arc::new(Mutex::new(Frames::default()));
        let permits = Arc::new(Semaphore::new(6));
        channel.on_message(Box::new(move |message| {
            let channel = receive_channel.clone(); let valid = receive_valid.clone();
            let state = state.clone(); let receiver = receiver.clone(); let permits = permits.clone();
            Box::pin(async move {
                if !valid.load(Ordering::Acquire) { return; }
                let now = match state.remote_calling.unix_time() { Ok(now) => now, Err(_) => return };
                if now >= expires_at { return; }
                let parsed = if message.is_string { Err("binary_peer_frame_required") }
                    else { receiver.lock().unwrap().receive(&message.data, REQUEST_LIMIT) };
                match parsed {
                    Ok(Some((request_id, bytes))) => {
                        let checked = serde_json::from_slice::<Value>(&bytes);
                        if checked.as_ref().is_ok_and(|v| v["type"] == "peer_hello" && v["sessionId"].as_str().and_then(|s|Uuid::parse_str(s).ok()) == Some(id)) && request_id == id {
                            if let Err(code) = send(&channel, id, json!({"type":"peer_ready","sessionId":id,"routerId":router,"agentTime":now})).await { eprintln!("[peer] {code}"); }
                            return;
                        }
                        if !checked.as_ref().is_ok_and(|v| v["requestId"].as_str().and_then(|s|Uuid::parse_str(s).ok()) == Some(request_id)) {
                            let _ = channel.close().await; return;
                        }
                        let permit = permits.try_acquire_owned();
                        let call = checked.ok().filter(|v| v["type"] == "peer_call").map(|v| (v["command"].clone(),v["proof"].clone()));
                        tokio::spawn(async move {
                            let (status, body) = match permit {
                                Ok(_permit) => {
                                    let outcome = tokio::task::spawn_blocking(move || {
                                        if let Some((command, proof)) = call {
                                            state.remote_calling.peer_command(phone, request_id, command, proof)
                                        } else { state.management.handle(&bytes, &state) }
                                    }).await;
                                    match outcome {
                                        Ok(value) => value,
                                        Err(_) => { eprintln!("[peer] management worker failed"); (500, json!({"ok":false,"error":"agent_execution_unknown"})) },
                                    }
                                },
                                Err(_) => (429, json!({"ok":false,"error":"agent_busy"})),
                            };
                            if !valid.load(Ordering::Acquire) { return; }
                            let body = serde_json::to_vec(&body).expect("JSON Value serialization");
                            if let Err(code) = send(&channel, request_id, json!({"type":"agent_result","requestId":request_id,
                                "status":status,"body":base64::engine::general_purpose::STANDARD.encode(body)})).await {
                                eprintln!("[peer] {code}");
                            }
                        });
                    },
                    Ok(None) => {},
                    Err(code) => { eprintln!("[peer] {code}"); let _ = channel.close().await; },
                }
            })
        }));
        let candidate_signals = signals.clone();
        peer.on_ice_candidate(Box::new(move |candidate| {
            let signals = candidate_signals.clone();
            Box::pin(async move {
                if let Some(candidate) = candidate {
                    match candidate.to_json() {
                        Ok(candidate) => { let _ = signals.send(json!({"type":"peer_signal","sessionId":id,"candidate":candidate})).await; },
                        Err(_) => eprintln!("[peer] candidate serialization failed"),
                    }
                }
            })
        }));
        let connection = Self { peer, expires_at, valid, channel, candidates: Vec::new() };
        let offered = async {
            let offer = connection.peer.create_offer(None).await.map_err(|_| "peer_offer_failed")?;
            connection.peer.set_local_description(offer.clone()).await.map_err(|_| "peer_description_failed")?;
            signals.send(json!({"type":"peer_signal","sessionId":id,"description":offer})).await.map_err(|_| "peer_signaling_closed")
        }.await;
        if let Err(code) = offered { connection.close().await; return Err(code); }
        Ok(connection)
    }
    pub async fn signal(&mut self, value: &Value) -> Result<(), &'static str> {
        if let Some(description) = value.get("description") {
            let description: RTCSessionDescription = serde_json::from_value(description.clone()).map_err(|_| "invalid_peer_description")?;
            if description.sdp_type != webrtc::peer_connection::sdp::sdp_type::RTCSdpType::Answer { return Err("peer_answer_required"); }
            self.peer.set_remote_description(description).await.map_err(|_| "peer_description_failed")?;
            for candidate in self.candidates.drain(..) {
                self.peer.add_ice_candidate(candidate).await.map_err(|_| "peer_candidate_failed")?;
            }
        } else if let Some(candidate) = value.get("candidate") {
            let candidate: RTCIceCandidateInit = serde_json::from_value(candidate.clone()).map_err(|_| "invalid_peer_candidate")?;
            if self.peer.remote_description().await.is_none() {
                if self.candidates.len() >= 64 { return Err("peer_candidate_capacity"); }
                self.candidates.push(candidate);
            } else { self.peer.add_ice_candidate(candidate).await.map_err(|_| "peer_candidate_failed")?; }
        } else { return Err("invalid_peer_signal"); }
        Ok(())
    }
    pub async fn close(self) {
        self.valid.store(false, Ordering::Release);
        self.channel.on_message(Box::new(|_| Box::pin(async {})));
        if self.channel.close().await.is_err() { eprintln!("[peer] channel close failed"); }
        if self.peer.close().await.is_err() { eprintln!("[peer] connection close failed"); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rendezvous_stun_contract_is_direct_only_and_requires_explicit_empty_credentials() {
        let servers = ice_servers(&json!([{"urls":["stun:nl1.gmdns.net:3478"],"username":"","credential":""}])).unwrap();
        assert_eq!(servers[0].urls, ["stun:nl1.gmdns.net:3478"]);
        assert!(ice_servers(&json!([{"urls":["stun:example.invalid:3478"]}])).is_err());
        assert!(ice_servers(&json!([{"urls":["turn:example.invalid:3478"],"username":"test","credential":"test"}])).is_err());
    }
    #[test]
    fn bounded_frames_reassemble_interleaved_messages_and_reject_bad_order() {
        let a = Uuid::new_v4(); let b = Uuid::new_v4();
        let left = vec![7; 65536]; let right = vec![13; MESSAGE_LIMIT];
        let mut receiver = Frames::default();
        let mut af = frames(a, &left).unwrap().into_iter();
        let mut bf = frames(b, &right).unwrap().into_iter();
        let mut complete = HashMap::new();
        while let Some(frame) = af.next().or_else(||bf.next()) {
            if let Some((id, data)) = receiver.receive(&frame, MESSAGE_LIMIT).unwrap() { complete.insert(id, data); }
            if let Some(frame) = bf.next() { if let Some((id, data)) = receiver.receive(&frame, MESSAGE_LIMIT).unwrap() { complete.insert(id, data); } }
        }
        assert_eq!(complete[&a], left); assert_eq!(complete[&b], right);
        let parts = frames(a, &left).unwrap();
        assert!(receiver.receive(&parts[1], MESSAGE_LIMIT).is_err());
        assert!(receiver.receive(&parts[0], REQUEST_LIMIT).unwrap().is_none());
        assert!(receiver.receive(&parts[0], REQUEST_LIMIT).is_err());
        assert!(Frames::default().receive(&frames(b, &right).unwrap()[0], REQUEST_LIMIT).is_err());
    }
}
