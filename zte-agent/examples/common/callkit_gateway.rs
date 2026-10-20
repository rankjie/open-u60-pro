use crate::{codec, media};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;
use webrtc::media::Sample;

struct Call {
    id: Uuid,
    direction: &'static str,
    state: &'static str,
    sequence: u64,
}
fn snapshot(call: &Call) -> Value {
    json!({"type":"call","callId":call.id,"routerId":"00000000-0000-4000-8000-000000000001", "direction":call.direction,"state":call.state,"number":"+999000001","mediaReady":call.state=="active", "updatedAt":1_800_000_000u64,"sequence":call.sequence})
}
async fn new_media(
    id: Uuid,
    tx: &mpsc::Sender<Value>,
    failure: &mpsc::Sender<media::Failure>,
    received: Arc<AtomicU64>,
) -> Result<media::Media, &'static str> {
    let value = media::Media::new(id, vec![], tx.clone(), failure.clone()).await?;
    value.peer.on_track(Box::new(move |track, _, _| {
        let counter = received.clone();
        Box::pin(async move {
            while let Ok((_, _)) = track.read_rtp().await {
                counter.fetch_add(1, Ordering::Relaxed);
            }
        })
    }));
    value.offer(tx).await?;
    Ok(value)
}
pub async fn run(bind: SocketAddr, allowed: IpAddr) -> Result<(), Box<dyn std::error::Error>> {
    if !matches!(bind.ip(),IpAddr::V4(ip) if ip.is_private())
        || !matches!(allowed,IpAddr::V4(ip) if ip.is_private())
    {
        return Err("private LAN addresses are required".into());
    }
    let listener = tokio::net::TcpListener::bind(bind).await?;
    println!("CallKit media fixture listening on private LAN");
    let (stream, from) = tokio::time::timeout(Duration::from_secs(60), listener.accept()).await??;
    if from.ip() != allowed {
        return Err("unexpected peer address".into());
    }
    let socket = tokio_tungstenite::accept_async(stream).await?;
    let (mut write, mut read) = socket.split();
    write.send(Message::Text(json!({"type":"hello","protocol":1,"role":"phone","endpointId":"00000000-0000-4000-8000-000000000002","routerId":"00000000-0000-4000-8000-000000000001","routerOnline":true,"voipPushConfigured":false,"calls":[],"iceServers":[]}).to_string().into())).await?;
    let (tx, mut signals) = mpsc::channel::<Value>(64);
    let (failure, mut failures) = mpsc::channel::<media::Failure>(8);
    let received = Arc::new(AtomicU64::new(0));
    let mut sent = 0u64;
    let mut call: Option<Call> = None;
    let mut peer: Option<media::Media> = None;
    let mut pending: Option<Value> = None;
    let mut audio = tokio::time::interval(Duration::from_millis(20));
    let mut stats = tokio::time::interval(Duration::from_millis(250));
    let deadline = tokio::time::sleep(Duration::from_secs(180));
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            _=&mut deadline=>break,
            value=signals.recv()=>{let value=value.ok_or("signaling_closed")?;write.send(Message::Text(value.to_string().into())).await?;},
            failure=failures.recv()=>{let _=failure.ok_or("failure_channel_closed")?;return Err("media_peer_failed".into());},
            input=read.next()=>{
                let Some(Ok(Message::Text(text)))=input else {break};let value:Value=serde_json::from_str(&text)?;
                match value["type"].as_str() {
                    Some("ping")=>{write.send(Message::Text(json!({"type":"pong"}).to_string().into())).await?;},
                    Some("probe_incoming")=>if call.is_none(){let c=Call{id:Uuid::new_v4(),direction:"incoming",state:"ringing",sequence:1};write.send(Message::Text(snapshot(&c).to_string().into())).await?;call=Some(c);},
                    Some("media_request")=>if let Some(c)=&call {if value["callId"].as_str()==Some(c.id.to_string().as_str()) {if let Some(old)=peer.take(){old.close().await;}peer=Some(new_media(c.id,&tx,&failure,received.clone()).await?);}},
                    Some("signal")=>if let Some(p)=peer.as_mut(){if value["callId"].as_str()==Some(p.call_id.to_string().as_str()){p.signal(&value).await?;}},
                    Some("command")=>{
                        let id=Uuid::parse_str(value["callId"].as_str().ok_or("missing_call")?)?;
                        match value["action"].as_str() {
                            Some("dial")=>{if call.is_some(){return Err("call_busy".into());}let c=Call{id,direction:"outgoing",state:"dialing",sequence:0};write.send(Message::Text(snapshot(&c).to_string().into())).await?;call=Some(c);peer=Some(new_media(id,&tx,&failure,received.clone()).await?);pending=Some(value);},
                            Some("answer")=>{if call.as_ref().is_none_or(|c|c.id!=id){return Err("wrong_call".into());}pending=Some(value);},
                            Some("hangup")=>{
                                write.send(Message::Text(json!({"type":"result","requestId":value["requestId"],"callId":id,"ok":true}).to_string().into())).await?;
                                if let Some(mut c)=call.take(){if c.id!=id{return Err("wrong_call".into());}c.state="ended";c.sequence+=1;write.send(Message::Text(snapshot(&c).to_string().into())).await?;}
                                if let Some(p)=peer.take(){p.close().await;}pending=None;
                                println!("Native CallKit media session ended: gateway sent={}, gateway received={}",sent,received.load(Ordering::Relaxed));
                            },
                            Some("dtmf")=>{write.send(Message::Text(json!({"type":"result","requestId":value["requestId"],"callId":id,"ok":true}).to_string().into())).await?;},
                            _=>return Err("unsupported_command".into()),
                        }
                    },
                    _=>return Err("unsupported_message".into()),
                }
            },
            _=audio.tick()=>if let Some(p)=&peer {if p.is_connected() {
                if let Some(value)=pending.take(){write.send(Message::Text(json!({"type":"result","requestId":value["requestId"],"callId":value["callId"],"ok":true}).to_string().into())).await?;let c=call.as_mut().ok_or("missing_call")?;c.state="active";c.sequence+=1;write.send(Message::Text(snapshot(c).to_string().into())).await?;}
                p.audio_track().write_sample(&Sample {data:vec![codec::encode(1000);160].into(),duration:Duration::from_millis(20),..Default::default()}).await?;sent+=1;
            }},
            _=stats.tick()=>{write.send(Message::Text(json!({"type":"probe_stats","sent":sent,"received":received.load(Ordering::Relaxed)}).to_string().into())).await?;},
        }
    }
    if let Some(p) = peer {
        p.close().await;
    }
    Ok(())
}
