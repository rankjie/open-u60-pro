//! relay-tunnel-gateway <identity-dir> <listen-udp-addr> <upstream>
//!
//! `upstream` is the service's TCP address, or another door (`quic://host:port#pin`) to chain
//! through, so a regional door can reach a distant service over QUIC as well.
//! Prints the certificate pin on start; clients need it with the address.

use std::net::SocketAddr;
use std::path::PathBuf;

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: relay-tunnel-gateway <identity-dir> <listen-udp-addr> <upstream-tcp-addr|quic://host:port#pin>");
        std::process::exit(2);
    }
    let directory = PathBuf::from(&args[1]);
    let Ok(listen) = args[2].parse::<SocketAddr>() else {
        eprintln!("listen address must be IP:port");
        std::process::exit(2);
    };
    // A chained door keeps its tunnel alive for the life of the gateway.
    let mut _chain = None;
    let upstream = if args[3].starts_with("quic://") {
        let door = match relay_tunnel::Door::parse(&args[3]) {
            Ok(door) => door,
            Err(error) => { eprintln!("upstream: {error}"); std::process::exit(2); }
        };
        let tunnel = match relay_tunnel::Tunnel::connect(door).await {
            Ok(tunnel) => tunnel,
            Err(error) => { eprintln!("upstream: {error}"); std::process::exit(1); }
        };
        let local = tunnel.local_addr();
        _chain = Some(tunnel);
        local
    } else {
        match args[3].parse::<SocketAddr>() {
            Ok(address) => address,
            Err(_) => { eprintln!("upstream must be IP:port or quic://host:port#pin"); std::process::exit(2); }
        }
    };
    let identity = match relay_tunnel::Identity::load_or_create(&directory) {
        Ok(identity) => identity,
        Err(error) => {
            eprintln!("identity: {error}");
            std::process::exit(1);
        }
    };
    let endpoint = match relay_tunnel::gateway(&identity, listen) {
        Ok(endpoint) => endpoint,
        Err(error) => {
            eprintln!("listen {listen}: {error}");
            std::process::exit(1);
        }
    };
    println!("relay-tunnel listening udp {listen} -> {} pin {}", args[3], identity.pin());
    relay_tunnel::serve(endpoint, upstream).await;
}
