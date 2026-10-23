//! Bounded native WebRTC fixtures. No modem or real pairing credential store is opened.
#[path = "../src/cellular_line.rs"]
mod cellular_line;
#[allow(dead_code)]
#[path = "../src/remote_calling/audio.rs"]
mod audio;
#[allow(dead_code)]
#[path = "../src/remote_calling/codec.rs"]
mod codec;
#[allow(dead_code)]
#[path = "../src/remote_calling/journal.rs"]
mod journal;
#[allow(dead_code)]
#[path = "../src/remote_calling/media.rs"]
mod media;
#[allow(dead_code)]
#[path = "../src/remote_calling/recordings.rs"]
mod recordings;
#[path = "common/server_gateway.rs"]
mod server_gateway;
#[allow(dead_code)]
#[path = "../src/remote_calling/storage.rs"]
mod storage;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;
use webrtc::media::Sample;

#[tokio::main]
async fn main() {
    if run().await.is_err() {
        eprintln!("Native media fixture failed");
        std::process::exit(1);
    }
}
async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() == 2 && args[0] == "--server" {
        return server_gateway::run(std::path::Path::new(&args[1])).await;
    }
    if !args.is_empty() {
        return Err("invalid_arguments".into());
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:49171").await?;
    println!("Native media fixture listening on loopback");
    let (stream, _) = tokio::time::timeout(Duration::from_secs(20), listener.accept()).await??;
    let socket = tokio_tungstenite::accept_async(stream).await?;
    let (mut write, mut read) = socket.split();
    let (tx, mut signals) = mpsc::channel(64);
    let (failure, mut errors) = mpsc::channel(8);
    let id = Uuid::new_v4();
    let peer = media::Media::new(id, vec![], tx.clone(), failure, Arc::new(tokio::sync::Notify::new()), None).await?;
    let received = Arc::new(AtomicU64::new(0));
    let counter = received.clone();
    peer.peer.on_track(Box::new(move |track, _, _| {
        let counter = counter.clone();
        Box::pin(async move {
            while let Ok((_, _)) = track.read_rtp().await {
                counter.fetch_add(1, Ordering::Relaxed);
            }
        })
    }));
    peer.offer(&tx).await?;
    let track = peer.audio_track();
    let mut peer = peer;
    let mut audio = tokio::time::interval(Duration::from_millis(20));
    let mut stats = tokio::time::interval(Duration::from_millis(100));
    let deadline = tokio::time::sleep(Duration::from_secs(20));
    tokio::pin!(deadline);
    let mut sent = 0u64;
    let result = loop {
        tokio::select! {
            _=&mut deadline=>break Err("native_media_timeout"),
            value=signals.recv()=>{let value=value.ok_or("media_signal_closed")?;write.send(Message::Text(value.to_string().into())).await?;},
            error=errors.recv()=>{let _=error.ok_or("media_error_channel_closed")?;break Err("native_peer_failed");},
            message=read.next()=>{
                let Some(Ok(Message::Text(text)))=message else {break Err("native_client_disconnected");};
                let value:Value=serde_json::from_str(&text)?;
                match value["type"].as_str() {
                    Some("signal")=>{if value["callId"].as_str()!=Some(id.to_string().as_str()) {break Err("wrong_call_identity");} peer.signal(&value).await?;},
                    Some("probe_done")=>{
                        if value["connected"]!=true || value["received"].as_u64().unwrap_or(0)==0 || sent==0 {break Err("native_media_not_delivered");}
                        println!("Real Google WebRTC interop passed: synthetic packets sent={}, native received={}, peer received={}",sent,value["received"],received.load(Ordering::Relaxed));
                        break Ok(());
                    },
                    Some("probe_error")=>break Err("native_client_rejected_media"),
                    _=>break Err("invalid_native_client_message"),
                }
            },
            _=audio.tick()=>if peer.is_connected() {
                track.write_sample(&Sample {data:vec![codec::encode(1000);160].into(),duration:Duration::from_millis(20),..Default::default()}).await?;sent+=1;
            },
            _=stats.tick()=>{write.send(Message::Text(json!({"type":"probe_stats","sent":sent}).to_string().into())).await?;},
        }
    };
    peer.close().await;
    result.map_err(Into::into)
}
