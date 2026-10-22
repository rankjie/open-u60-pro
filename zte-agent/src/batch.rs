//! `POST /api/batch`: several reads answered by one request.
//!
//! A dashboard tick reads a dozen endpoints. Over the relay or the P2P channel
//! each read is a full round trip and a management slot; batched, the tick is
//! one. Sub-requests are GET-only, so the batch is a read wherever the
//! management journal or the relay classifies requests.

use serde::Deserialize;
use serde_json::{json, Value};

pub const MAX_REQUESTS: usize = 16;
/// Sub-reads fork ubus/uci; bound how many one batch runs at once.
const PARALLELISM: usize = 6;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Batch {
    requests: Vec<Entry>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: String,
}

pub fn handle(state: &crate::handlers::AppState, body: &[u8]) -> (u16, Value) {
    execute(body, |path| {
        crate::server::route(&tiny_http::Method::Get, path, state, &[])
    })
}

fn execute(body: &[u8], read: impl Fn(&str) -> (u16, Value) + Sync) -> (u16, Value) {
    let paths = match parse(body) {
        Ok(paths) => paths,
        Err(code) => return (400, json!({"ok": false, "error": code})),
    };
    let mut responses = Vec::with_capacity(paths.len());
    for chunk in paths.chunks(PARALLELISM) {
        let results: Vec<(u16, Value)> = std::thread::scope(|scope| {
            let handles: Vec<_> = chunk
                .iter()
                .map(|path| scope.spawn(|| read(path)))
                .collect();
            handles
                .into_iter()
                .map(|handle| {
                    handle
                        .join()
                        .unwrap_or_else(|_| (500, json!({"ok": false, "error": "batch_read_panicked"})))
                })
                .collect()
        });
        responses.extend(
            results
                .into_iter()
                .map(|(status, body)| json!({"status": status, "body": body})),
        );
    }
    (200, json!({"ok": true, "data": {"responses": responses}}))
}

fn parse(body: &[u8]) -> Result<Vec<String>, &'static str> {
    let batch: Batch = serde_json::from_slice(body).map_err(|_| "invalid_batch")?;
    if batch.requests.is_empty() || batch.requests.len() > MAX_REQUESTS {
        return Err("invalid_batch_size");
    }
    batch
        .requests
        .into_iter()
        .map(|entry| {
            if allowed(&entry.path) {
                Ok(entry.path)
            } else {
                Err("batch_path_forbidden")
            }
        })
        .collect()
}

/// The same path rules as a management request, so batching cannot reach a
/// route the relay forbids; batches do not nest.
fn allowed(path: &str) -> bool {
    path.len() <= 256
        && path.starts_with("/api/")
        && !path.contains("//")
        && path
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"/-".contains(&b))
        && ![
            "auth",
            "remote-calling",
            "live-activity",
            "lan",
            "management",
            "identity",
            "calling",
            "batch",
        ]
        .iter()
        .any(|part| path == format!("/api/{part}") || path.starts_with(&format!("/api/{part}/")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn body(paths: &[&str]) -> Vec<u8> {
        let requests: Vec<Value> = paths.iter().map(|path| json!({"path": path})).collect();
        serde_json::to_vec(&json!({"requests": requests})).unwrap()
    }

    #[test]
    fn responses_keep_request_order_and_individual_status() {
        let paths = [
            "/api/battery", "/api/cpu", "/api/missing", "/api/network/signal",
            "/api/device/thermal", "/api/wifi/status", "/api/device/charger",
        ];
        let (status, value) = execute(&body(&paths), |path| {
            if path == "/api/missing" {
                (404, json!({"ok": false, "error": "not_found"}))
            } else {
                (200, json!({"ok": true, "data": {"path": path}}))
            }
        });
        assert_eq!(status, 200);
        let responses = value["data"]["responses"].as_array().unwrap();
        assert_eq!(responses.len(), paths.len());
        for (response, path) in responses.iter().zip(paths) {
            if path == "/api/missing" {
                assert_eq!(response["status"], 404);
                assert_eq!(response["body"]["error"], "not_found");
            } else {
                assert_eq!(response["status"], 200);
                assert_eq!(response["body"]["data"]["path"], path);
            }
        }
    }

    #[test]
    fn reads_run_concurrently_within_the_parallelism_bound() {
        let active = AtomicUsize::new(0);
        let peak = AtomicUsize::new(0);
        let paths: Vec<String> = (0..MAX_REQUESTS).map(|i| format!("/api/read-{i}")).collect();
        let refs: Vec<&str> = paths.iter().map(String::as_str).collect();
        let (status, _) = execute(&body(&refs), |_| {
            let now = active.fetch_add(1, Ordering::SeqCst) + 1;
            peak.fetch_max(now, Ordering::SeqCst);
            std::thread::sleep(std::time::Duration::from_millis(20));
            active.fetch_sub(1, Ordering::SeqCst);
            (200, json!({"ok": true}))
        });
        assert_eq!(status, 200);
        let peak = peak.load(Ordering::SeqCst);
        assert!(peak > 1, "reads were serialized");
        assert!(peak <= PARALLELISM, "peak {peak} exceeded the bound");
    }

    #[test]
    fn forbidden_nested_or_malformed_requests_run_nothing() {
        let ran = AtomicUsize::new(0);
        for invalid in [
            body(&[]),
            body(&vec!["/api/battery"; MAX_REQUESTS + 1]),
            body(&["/api/battery", "/api/batch"]),
            body(&["/api/auth/login"]),
            body(&["/api/remote-calling/status"]),
            body(&["/api/management"]),
            body(&["/api/sms/list?page=1"]),
            body(&["/api//battery"]),
            body(&["/etc/passwd"]),
            br#"{"requests":[{"path":"/api/battery","method":"POST"}]}"#.to_vec(),
            b"not json".to_vec(),
        ] {
            let (status, value) = execute(&invalid, |_| {
                ran.fetch_add(1, Ordering::SeqCst);
                (200, json!({"ok": true}))
            });
            assert_eq!(status, 400, "{}", String::from_utf8_lossy(&invalid));
            assert_eq!(value["ok"], false);
        }
        assert_eq!(ran.load(Ordering::SeqCst), 0);
    }
}
