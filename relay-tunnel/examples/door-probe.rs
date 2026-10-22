//! door-probe quic://host:port#pin
//! Opens the door, prints its round-trip time and a loopback address to send HTTP through,
//! then keeps the tunnel open until interrupted.

#[tokio::main]
async fn main() {
    let address = std::env::args().nth(1).expect("usage: door-probe quic://host:port#pin");
    let door = relay_tunnel::Door::parse(&address).expect("invalid door");
    let tunnel = relay_tunnel::Tunnel::connect(door).await.expect("door unreachable");
    let rtt = tunnel.probe().await.expect("QUIC handshake failed");
    println!("rtt {} ms local http://{}", rtt.as_millis(), tunnel.local_addr());
    tokio::signal::ctrl_c().await.ok();
}
