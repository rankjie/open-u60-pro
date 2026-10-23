use crate::{codec, media, storage};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    io::BufRead,
    path::Path,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::mpsc;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, http::HeaderValue, Message},
};
use uuid::Uuid;
use webrtc::{ice_transport::ice_server::RTCIceServer, media::Sample};

async fn transport_summary(peer: &media::Media) {
    if let Some(pair) = peer
        .peer
        .sctp()
        .transport()
        .ice_transport()
        .get_selected_candidate_pair()
        .await
    {
        println!(
            "ICE route: local={}/{}, remote={}/{}",
            pair.local.typ, pair.local.protocol, pair.remote.typ, pair.remote.protocol
        );
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    #[serde(rename = "serverURL")]
    server_url: String,
    token: String,
}
struct Call {
    id: Uuid,
    sequence: u64,
}
fn event(call: &mut Call, state: &str) -> Result<Value, &'static str> {
    call.sequence += 1;
    Ok(
        json!({"type":"event","eventId":Uuid::new_v4(),"callId":call.id,"sequence":call.sequence,
        "observedAt":SystemTime::now().duration_since(UNIX_EPOCH).map_err(|_|"invalid_clock")?.as_secs(),
        "state":state,"mediaReady":state=="active","number":"+999000001","reason":"synthetic_probe_complete"}),
    )
}
async fn peer(
    id: Uuid,
    servers: &[RTCIceServer],
    tx: &mpsc::Sender<Value>,
    failed: &mpsc::Sender<media::Failure>,
    rx: Arc<AtomicU64>,
) -> Result<media::Media, &'static str> {
    let value = media::Media::new(id, servers.to_vec(), tx.clone(), failed.clone(), Arc::new(tokio::sync::Notify::new()))
        .await
        .map_err(|code| {
            eprintln!("Native fixture media creation: {code}");
            code
        })?;
    value.peer.on_track(Box::new(move |track, _, _| {
        let counter = rx.clone();
        Box::pin(async move {
            while let Ok((packet, _)) = track.read_rtp().await {
                if packet.header.payload_type == 0 && !packet.payload.is_empty() {
                    counter.fetch_add(1, Ordering::Relaxed);
                }
            }
        })
    }));
    value.offer(tx).await?;
    Ok(value)
}
pub async fn run(file: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let config: Config = serde_json::from_slice(&storage::private_read(file)?)?;
    let address = config
        .server_url
        .strip_prefix("https://")
        .ok_or("https_required")?;
    let mut request = format!("wss://{address}/v1/socket").into_client_request()?;
    request.headers_mut().insert(
        "authorization",
        HeaderValue::from_str(&format!("Bearer {}", config.token))?,
    );
    let (socket, _) = connect_async(request).await?;
    let (mut write, mut read) = socket.split();
    let (control, mut commands) = mpsc::channel(8);
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line {
                Ok(line) => {
                    if control.blocking_send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
    let (signals, mut outgoing) = mpsc::channel::<Value>(64);
    let (failure, mut failures) = mpsc::channel::<media::Failure>(8);
    let received = Arc::new(AtomicU64::new(0));
    let mut sent = 0u64;
    let mut servers: Vec<RTCIceServer> = Vec::new();
    let mut current: Option<Call> = None;
    let mut media: Option<media::Media> = None;
    let mut pending: Option<Value> = None;
    let mut phase = 0f64;
    let mut audio = tokio::time::interval(Duration::from_millis(20));
    let mut ping = tokio::time::interval(Duration::from_secs(10));
    let deadline = tokio::time::sleep(Duration::from_secs(600));
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            _=&mut deadline=>break,
            input=commands.recv()=>{match input.as_deref() {
                Some("ring") if current.is_none()=>{sent=0;received.store(0,Ordering::Relaxed);let mut c=Call{id:Uuid::new_v4(),sequence:0};write.send(Message::Text(event(&mut c,"ringing")?.to_string().into())).await?;current=Some(c);println!("Synthetic incoming event submitted to the real APNs-enabled service");},
                Some("hangup")=>{if let Some(mut c)=current.take(){write.send(Message::Text(event(&mut c,"ended")?.to_string().into())).await?;}if let Some(p)=media.take(){p.close().await;}pending=None;println!("Synthetic session ended: PCMU sent={sent}, received={}",received.load(Ordering::Relaxed));},
                Some("quit")|None=>break,
                _=>println!("Supported controls: ring, hangup, quit"),
            }},
            value=outgoing.recv()=>{let value=value.ok_or("signal_channel_closed")?;write.send(Message::Text(value.to_string().into())).await?;},
            value=failures.recv()=>{let (generation,code)=value.ok_or("failure_channel_closed")?;if media.as_ref().is_some_and(|p|p.generation==generation){eprintln!("Native fixture peer failure: {code}");return Err("media_failed".into());}},
            input=read.next()=>{
                let text=match input {
                    Some(Ok(Message::Text(text)))=>text,
                    Some(Ok(Message::Ping(_)|Message::Pong(_)))=>continue,
                    _=>return Err("gateway_socket_closed".into()),
                };let value:Value=serde_json::from_str(&text)?;
                match value["type"].as_str() {
                    Some("hello")=>{servers=serde_json::from_value(value["iceServers"].clone())?;println!("Synthetic router ready on authenticated public WSS; controls: ring, hangup, quit");},
                    Some("ice_servers")=>{servers=serde_json::from_value(value["iceServers"].clone())?;},
                    Some("media_request")=>{println!("Gateway preparing media for the waking phone");let id=Uuid::parse_str(value["callId"].as_str().ok_or("missing_call_id")?)?;if current.as_ref().is_some_and(|c|c.id==id){if let Some(old)=media.take(){old.close().await;}media=Some(peer(id,&servers,&signals,&failure,received.clone()).await?);}},
                    Some("signal")=>{if let Some(p)=media.as_mut(){p.signal(&value).await.map_err(|code| {eprintln!("Native fixture signaling: {code}");code})?;}},
                    Some("command")=>{
                        let id=Uuid::parse_str(value["callId"].as_str().ok_or("missing_call_id")?)?;
                        match value["action"].as_str() {
                            Some("answer")=>{if current.as_ref().is_none_or(|c|c.id!=id){return Err("wrong_call".into());}pending=Some(value);},
                            Some("hangup")=>{write.send(Message::Text(json!({"type":"result","requestId":value["requestId"],"callId":id,"ok":true}).to_string().into())).await?;current=None;if let Some(p)=media.take(){transport_summary(&p).await;p.close().await;}pending=None;println!("CallKit hangup completed: PCMU sent={sent}, received={}",received.load(Ordering::Relaxed));},
                            _=>return Err("unsupported_command".into()),
                        }
                    },
                    Some("error")=>{let code=value["error"].as_str().ok_or("missing_error")?;if code!="peer_offline" && code!="call_ended" {return Err("server_rejected_fixture".into());}},
                    Some("call") if value["state"]=="ended"=>{if let Some(p)=media.take(){p.close().await;}current=None;pending=None;println!("Server ended synthetic call: PCMU sent={sent}, received={}",received.load(Ordering::Relaxed));},
                    Some("paired"|"pong"|"call"|"event_ack")=>{},
                    _=>return Err("unsupported_server_message".into()),
                }
            },
            _=ping.tick()=>{write.send(Message::Text(json!({"type":"ping"}).to_string().into())).await?;},
            _=audio.tick()=>if let Some(p)=&media {if p.is_connected() {
                if let Some(value)=pending.take(){write.send(Message::Text(json!({"type":"result","requestId":value["requestId"],"callId":value["callId"],"ok":true}).to_string().into())).await?;let c=current.as_mut().ok_or("missing_current_call")?;write.send(Message::Text(event(c,"active")?.to_string().into())).await?;println!("CallKit answer negotiated real DTLS-SRTP");}
                let samples=(0..160).map(|_|{let value=(phase.sin()*1200.0) as i16;phase=(phase+std::f64::consts::TAU*440.0/8000.0)%std::f64::consts::TAU;codec::encode(value)}).collect::<Vec<_>>();
                p.audio_track().write_sample(&Sample{data:samples.into(),duration:Duration::from_millis(20),..Default::default()}).await?;sent+=1;
            }},
        }
    }
    if let Some(mut call) = current {
        write
            .send(Message::Text(event(&mut call, "ended")?.to_string().into()))
            .await?;
    }
    if let Some(p) = media {
        p.close().await;
    }
    Ok(())
}
