use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::time::Duration;

use relay_tunnel::{gateway, serve, Identity, Pin, Tunnel};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("relay-tunnel-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

/// Reads one request to EOF (the client half-closes), then answers with a body that names it.
async fn upstream() -> SocketAddr {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut request = Vec::new();
                socket.read_to_end(&mut request).await.unwrap();
                let mut reply = b"echo:".to_vec();
                reply.extend_from_slice(&request);
                socket.write_all(&reply).await.unwrap();
            });
        }
    });
    address
}

async fn start_gateway(dir: &PathBuf, upstream: SocketAddr, port: u16) -> (SocketAddr, Pin, quinn::Endpoint) {
    let identity = Identity::load_or_create(dir).unwrap();
    let endpoint = gateway(&identity, (Ipv4Addr::LOCALHOST, port).into()).unwrap();
    let address = endpoint.local_addr().unwrap();
    let pin = identity.pin();
    tokio::spawn(serve(endpoint.clone(), upstream));
    (address, pin, endpoint)
}

async fn exchange(local: SocketAddr, payload: &[u8]) -> std::io::Result<Vec<u8>> {
    let mut socket = TcpStream::connect(local).await?;
    socket.write_all(payload).await?;
    socket.shutdown().await?;
    let mut reply = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), socket.read_to_end(&mut reply)).await??;
    Ok(reply)
}

#[tokio::test]
async fn streams_carry_tcp_connections_byte_for_byte() {
    let dir = temp_dir("bytes");
    let (address, pin, _gateway) = start_gateway(&dir, upstream().await, 0).await;
    let tunnel = Tunnel::start(address, pin).await.unwrap();
    assert!(tunnel.probe().await.unwrap() < Duration::from_secs(1));

    // A large body crosses many QUIC packets and arrives intact after the client's half-close.
    let large: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    let reply = exchange(tunnel.local_addr(), &large).await.unwrap();
    assert_eq!(&reply[..5], b"echo:");
    assert_eq!(&reply[5..], &large[..]);

    // Concurrent connections share one QUIC connection without mixing bytes.
    let tasks: Vec<_> = (0..40)
        .map(|i| {
            let local = tunnel.local_addr();
            tokio::spawn(async move {
                let body = format!("request-{i}").into_bytes();
                (exchange(local, &body).await.unwrap(), body)
            })
        })
        .collect();
    for task in tasks {
        let (reply, body) = task.await.unwrap();
        assert_eq!(reply, [b"echo:".as_slice(), &body].concat());
    }
}

#[tokio::test]
async fn a_gateway_with_another_certificate_is_refused() {
    let dir = temp_dir("pin");
    let (address, _, _gateway) = start_gateway(&dir, upstream().await, 0).await;
    let wrong = Pin([7; 32]);
    let tunnel = Tunnel::start(address, wrong).await.unwrap();
    assert!(tunnel.probe().await.is_err());
    // The application sees a closed connection, never upstream data.
    let reply = exchange(tunnel.local_addr(), b"secret").await;
    assert!(reply.map(|r| r.is_empty()).unwrap_or(true));
}

#[tokio::test]
async fn the_pin_survives_restarts_and_clients_reconnect() {
    let dir = temp_dir("restart");
    let upstream = upstream().await;
    let (address, pin, first) = start_gateway(&dir, upstream, 0).await;
    let tunnel = Tunnel::start(address, pin).await.unwrap();
    assert_eq!(exchange(tunnel.local_addr(), b"one").await.unwrap(), b"echo:one");

    // A process restart: the old endpoint releases its UDP port.
    first.close(0u32.into(), b"restart");
    first.wait_idle().await;
    drop(first);
    // The endpoint driver releases the socket asynchronously after close.
    let mut endpoint = None;
    for _ in 0..50 {
        let identity = Identity::load_or_create(&dir).unwrap();
        if let Ok(rebound) = gateway(&identity, address) { endpoint = Some((rebound, identity.pin())); break }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let (second, pin_again) = endpoint.expect("the port is released after close");
    let again = second.local_addr().unwrap();
    tokio::spawn(serve(second, upstream));
    assert_eq!(again, address);
    assert_eq!(pin_again, pin, "the identity is reused, so clients keep their pin");

    // The old QUIC connection is gone; the next TCP connection opens a new one.
    let mut reply = Err(std::io::Error::other("no attempt"));
    for _ in 0..20 {
        reply = exchange(tunnel.local_addr(), b"two").await;
        if matches!(&reply, Ok(r) if r == b"echo:two") { break }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    assert_eq!(reply.unwrap(), b"echo:two");
}

#[test]
fn pins_round_trip_as_unpadded_base64url() {
    let pin = Pin::of(b"certificate");
    assert_eq!(Pin::parse(&pin.to_string()), Ok(pin));
    assert_eq!(pin.to_string().len(), 43);
    assert!(Pin::parse("not a pin").is_err());
    assert!(Pin::parse("AAAA").is_err());
}

#[test]
fn door_addresses_carry_host_port_and_pin() {
    let pin = Pin::of(b"certificate");
    let door = relay_tunnel::Door::parse(&format!("quic://203.0.113.5:47853#{pin}")).unwrap();
    assert_eq!((door.host.as_str(), door.port, door.pin), ("203.0.113.5", 47853, pin));
    assert_eq!(relay_tunnel::Door::parse(&door.to_string()), Ok(door));
    let v6 = relay_tunnel::Door::parse(&format!("quic://[2001:db8::1]:443#{pin}")).unwrap();
    assert_eq!(v6.host, "2001:db8::1");
    assert_eq!(relay_tunnel::Door::parse(&v6.to_string()), Ok(v6));
    let named = relay_tunnel::Door::parse(&format!("quic://relay.example:9000/#{pin}")).unwrap();
    assert_eq!(named.host, "relay.example");
    for bad in [
        format!("https://203.0.113.5:47853#{pin}"),
        format!("quic://203.0.113.5#{pin}"),
        "quic://203.0.113.5:47853".to_string(),
        format!("quic://user@203.0.113.5:47853#{pin}"),
        format!("quic://203.0.113.5:99999#{pin}"),
    ] {
        assert!(relay_tunnel::Door::parse(&bad).is_err(), "{bad}");
    }
}

#[tokio::test]
async fn a_door_can_chain_through_another_door() {
    let far_dir = temp_dir("chain-far");
    let near_dir = temp_dir("chain-near");
    let (far, far_pin, _far) = start_gateway(&far_dir, upstream().await, 0).await;
    let hop = Tunnel::connect(relay_tunnel::Door { host: "127.0.0.1".into(), port: far.port(), pin: far_pin })
        .await
        .unwrap();
    let (near, near_pin, _near) = start_gateway(&near_dir, hop.local_addr(), 0).await;
    let client = Tunnel::start(near, near_pin).await.unwrap();
    assert_eq!(exchange(client.local_addr(), b"through two doors").await.unwrap(), b"echo:through two doors");
}

#[tokio::test]
async fn a_finished_empty_request_still_reaches_upstream() {
    // Streams that are opened and never finished (Network.framework's) open no upstream
    // connection; that is covered by the iOS forwarder test. A clean, empty request does.
    let dir = temp_dir("empty");
    let (address, pin, _gateway) = start_gateway(&dir, upstream().await, 0).await;
    let tunnel = Tunnel::start(address, pin).await.unwrap();
    assert_eq!(exchange(tunnel.local_addr(), b"").await.unwrap(), b"echo:");
}

#[tokio::test]
async fn a_restarted_gateway_resets_old_connections_at_once() {
    use std::process::{Command, Stdio};
    use std::io::BufRead;
    let dir = temp_dir("reset");
    let upstream = upstream().await;
    let port = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap().local_addr().unwrap().port();
    let start = || {
        let mut child = Command::new(env!("CARGO_BIN_EXE_relay-tunnel-gateway"))
            .args([dir.to_str().unwrap(), &format!("127.0.0.1:{port}"), &upstream.to_string()])
            .stdout(Stdio::piped()).spawn().unwrap();
        let mut line = String::new();
        std::io::BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let pin = Pin::parse(line.trim().rsplit(' ').next().unwrap()).unwrap();
        (child, pin)
    };
    let (mut first, pin) = start();
    let address: SocketAddr = (Ipv4Addr::LOCALHOST, port).into();
    let tunnel = Tunnel::start(address, pin).await.unwrap();
    assert_eq!(exchange(tunnel.local_addr(), b"one").await.unwrap(), b"echo:one");
    // A crash: SIGKILL sends no close; the client still holds the old connection.
    first.kill().unwrap();
    first.wait().unwrap();
    let (mut second, pin_again) = start();
    assert_eq!(pin_again, pin);
    // Without the persistent reset key this waits for the 60 s idle timeout.
    let started = std::time::Instant::now();
    let mut reply = Err(std::io::Error::other("no attempt"));
    while started.elapsed() < Duration::from_secs(10) {
        reply = exchange(tunnel.local_addr(), b"two").await;
        if matches!(&reply, Ok(r) if r == b"echo:two") { break }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    second.kill().unwrap();
    assert_eq!(reply.unwrap(), b"echo:two");
    assert!(started.elapsed() < Duration::from_secs(10), "took {:?}", started.elapsed());
}
