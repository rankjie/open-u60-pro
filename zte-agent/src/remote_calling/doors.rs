//! Paths to the calling server: its HTTPS address, plus the QUIC doors it advertises.
//!
//! A door is a regional QUIC gateway that forwards to the same service, so identity, pairing
//! and calls are unchanged whichever path is used. Before each connection the router probes
//! every path end to end (an authenticated status request) and uses the fastest that answers.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use relay_tunnel::{Door, Tunnel};

use super::Config;

const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Route {
    /// Base URL for HTTP requests: the server URL, or the door tunnel's loopback address.
    pub base: String,
    /// "direct" or the door address, for status reporting.
    pub via: String,
}

impl Route {
    fn direct(config: &Config) -> Self {
        Route { base: config.server_url.trim_end_matches('/').to_string(), via: "direct".into() }
    }

    pub fn url(&self, path: &str) -> String {
        format!("{}/{}", self.base, path)
    }

    /// WebSocket URL: TLS for the direct path; the door already encrypts its loopback hop.
    pub fn socket_url(&self, path: &str) -> String {
        let url = self.url(path);
        if let Some(rest) = url.strip_prefix("https://") {
            format!("wss://{rest}")
        } else {
            url.replacen("http://", "ws://", 1)
        }
    }
}

#[derive(Default)]
pub(super) struct Doors {
    tunnels: tokio::sync::Mutex<HashMap<String, Tunnel>>,
    current: std::sync::Mutex<Option<Route>>,
}

impl Doors {
    /// The path chosen by the last selection, or the direct address before any.
    pub fn route(&self, config: &Config) -> Route {
        self.current.lock().unwrap().clone().unwrap_or_else(|| Route::direct(config))
    }

    pub async fn select(&self, config: &Config) -> Route {
        let mut candidates = vec![Route::direct(config)];
        {
            let mut tunnels = self.tunnels.lock().await;
            // Doors the server no longer advertises are closed.
            tunnels.retain(|address, _| config.doors.contains(address));
            for address in &config.doors {
                let Ok(door) = Door::parse(address) else { continue };
                if !tunnels.contains_key(address) {
                    match Tunnel::connect(door).await {
                        Ok(tunnel) => {
                            tunnels.insert(address.clone(), tunnel);
                        }
                        Err(error) => {
                            eprintln!("[doors] {address}: {error}");
                            continue;
                        }
                    }
                }
                let local = tunnels[address].local_addr();
                candidates.push(Route { base: format!("http://{local}"), via: address.clone() });
            }
        }
        // The first path to answer is the fastest; a dead door costs nothing once one answers.
        let mut probes: futures_util::stream::FuturesUnordered<_> = candidates.into_iter().map(|route| async {
            let elapsed = probe(&route, &config.device_token).await;
            (route, elapsed)
        }).collect();
        let mut chosen = None;
        while let Some((route, elapsed)) = futures_util::StreamExt::next(&mut probes).await {
            if elapsed.is_some() { chosen = Some(route); break; }
        }
        let chosen = chosen.unwrap_or_else(|| Route::direct(config));
        if chosen.via != "direct" {
            eprintln!("[doors] using {}", chosen.via);
        }
        *self.current.lock().unwrap() = Some(chosen.clone());
        chosen
    }
}

async fn probe(route: &Route, token: &str) -> Option<Duration> {
    let client = reqwest::Client::builder().no_proxy().timeout(PROBE_TIMEOUT).build().ok()?;
    let started = Instant::now();
    let response = client.get(route.url("v1/status")).bearer_auth(token).send().await.ok()?;
    response.status().is_success().then(|| started.elapsed())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// An HTTP status endpoint that answers after `delay`.
    async fn status_server(delay: Duration) -> std::net::SocketAddr {
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut request = [0; 2048];
                    let _ = socket.read(&mut request).await;
                    tokio::time::sleep(delay).await;
                    let _ = socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}").await;
                });
            }
        });
        address
    }

    fn config(server: String, doors: Vec<String>) -> Config {
        Config { enabled: true, server_url: server, device_token: "t".repeat(43), request_id: uuid::Uuid::new_v4(),
                 endpoint_id: None, invitation: None, doors }
    }

    #[tokio::test]
    async fn the_first_path_to_answer_wins_without_waiting_for_dead_doors() {
        let slow = status_server(Duration::from_millis(600)).await;
        let fast = status_server(Duration::ZERO).await;
        let dir = std::env::temp_dir().join(format!("doors-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let identity = relay_tunnel::Identity::load_or_create(&dir).unwrap();
        let gateway = relay_tunnel::gateway(&identity, (Ipv4Addr::LOCALHOST, 0).into()).unwrap();
        let door = format!("quic://127.0.0.1:{}#{}", gateway.local_addr().unwrap().port(), identity.pin());
        tokio::spawn(relay_tunnel::serve(gateway, fast));
        let dead_port = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap().local_addr().unwrap().port();
        let dead = format!("quic://127.0.0.1:{dead_port}#{}", identity.pin());

        let doors = Doors::default();
        let started = Instant::now();
        let chosen = doors.select(&config(format!("http://{slow}"), vec![dead.clone(), door.clone()])).await;
        assert_eq!(chosen.via, door);
        assert!(started.elapsed() < Duration::from_millis(1500), "waited {:?}", started.elapsed());
        assert_eq!(doors.route(&config(String::new(), vec![])).via, door);

        // With no door answering, the direct address is used even though it is slower.
        let chosen = doors.select(&config(format!("http://{slow}"), vec![dead])).await;
        assert_eq!(chosen.via, "direct");
        assert_eq!(chosen.base, format!("http://{slow}"));
    }

    #[test]
    fn socket_urls_keep_tls_on_the_direct_path_only() {
        let direct = Route { base: "https://relay.example/openu60".into(), via: "direct".into() };
        assert_eq!(direct.socket_url("v1/socket"), "wss://relay.example/openu60/v1/socket");
        let door = Route { base: "http://127.0.0.1:50123".into(), via: "quic://x:1#p".into() };
        assert_eq!(door.socket_url("v1/socket"), "ws://127.0.0.1:50123/v1/socket");
        assert_eq!(door.url("v1/enroll"), "http://127.0.0.1:50123/v1/enroll");
    }
}
