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
        let probes = candidates.into_iter().map(|route| async {
            let elapsed = probe(&route, &config.device_token).await;
            (route, elapsed)
        });
        let results = futures_util::future::join_all(probes).await;
        let chosen = choose(&results).unwrap_or_else(|| Route::direct(config));
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

/// The fastest path that answered. Ties keep the earlier candidate, so direct wins a tie.
fn choose(results: &[(Route, Option<Duration>)]) -> Option<Route> {
    results
        .iter()
        .filter_map(|(route, elapsed)| elapsed.map(|elapsed| (route, elapsed)))
        .min_by_key(|(_, elapsed)| *elapsed)
        .map(|(route, _)| route.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn route(via: &str) -> Route {
        Route { base: format!("http://{via}"), via: via.into() }
    }

    #[test]
    fn the_fastest_answering_path_wins_and_failures_never_do() {
        let results = vec![
            (route("direct"), Some(Duration::from_millis(320))),
            (route("hangzhou"), Some(Duration::from_millis(40))),
            (route("broken"), None),
            (route("hongkong"), Some(Duration::from_millis(90))),
        ];
        assert_eq!(choose(&results).unwrap().via, "hangzhou");
        assert_eq!(choose(&[(route("broken"), None)]), None);
        let tie = vec![(route("direct"), Some(Duration::from_millis(50))), (route("door"), Some(Duration::from_millis(50)))];
        assert_eq!(choose(&tie).unwrap().via, "direct");
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
