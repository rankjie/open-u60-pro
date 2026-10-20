use std::process::Command;
use std::sync::{Mutex, MutexGuard};

const PORTS: &[&str] = &[
    "/dev/at_mdm0",
    "/dev/at_mdm1",
    "/dev/at_usb0",
    "/dev/smd7",
    "/dev/smd11",
];

/// Serialises every AT exchange process-wide. The modem node is a packet
/// device with a single receive queue shared by all opens, so two concurrent
/// `cat` readers split (or steal) each other's reply; HTTP workers, the AT
/// terminal, the policy threads and `busy_check` all go through here.
static AT_LOCK: Mutex<()> = Mutex::new(());

fn lock_port() -> MutexGuard<'static, ()> {
    AT_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

pub struct AtPort {
    cached: Mutex<Option<String>>,
}

impl AtPort {
    pub fn new() -> Self {
        Self {
            cached: Mutex::new(None),
        }
    }

    pub fn detect(&self) -> Option<String> {
        if let Some(port) = self.cached() {
            return Some(port);
        }
        let _g = lock_port();
        self.probe()
    }

    fn cached(&self) -> Option<String> {
        self.cached.lock().unwrap().clone()
    }

    /// Probe the candidate ports with a bare `AT`. Caller must hold `AT_LOCK`.
    fn probe(&self) -> Option<String> {
        if let Some(port) = self.cached() {
            return Some(port);
        }

        for &port in PORTS {
            if !std::path::Path::new(port).exists() {
                continue;
            }
            let script = format!(
                "cat {p} & PID=$! ; sleep 0.3 ; echo -e 'AT\\r' > {p} ; sleep 1 ; kill $PID 2>/dev/null",
                p = port
            );
            let output = Command::new("sh").args(["-c", &script]).output().ok();
            if let Some(out) = output {
                let resp = String::from_utf8_lossy(&out.stdout);
                if resp.contains("OK") {
                    let mut cached = self.cached.lock().unwrap();
                    *cached = Some(port.to_string());
                    return Some(port.to_string());
                }
            }
        }
        None
    }
}

/// Send an AT command and return the raw response text.
///
/// Holds `AT_LOCK` for the whole exchange (port probe included) so no two
/// commands ever share the node's receive queue.
pub fn send(at_port: &AtPort, command: &str, timeout_secs: u64) -> Result<String, String> {
    let _g = lock_port();
    exchange(at_port, command, timeout_secs, None)
}

/// Remote calls must be cancellable while waiting behind local AT traffic.
/// Once an exchange starts, its finite response window is allowed to complete
/// so the call owner can reconcile and hang up a submitted dial.
pub fn send_cancellable(
    at_port: &AtPort,
    command: &str,
    timeout_secs: u64,
    cancelled: &std::sync::atomic::AtomicBool,
) -> Result<String, String> {
    use std::sync::{atomic::Ordering, TryLockError};
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let _guard = loop {
        if cancelled.load(Ordering::Acquire) {
            return Err("exchange_cancelled".into());
        }
        match AT_LOCK.try_lock() {
            Ok(guard) => break guard,
            Err(TryLockError::Poisoned(error)) => break error.into_inner(),
            Err(TryLockError::WouldBlock) => {
                if std::time::Instant::now() >= deadline {
                    return Err("port_busy".into());
                }
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
        }
    };
    exchange(at_port, command, timeout_secs, Some(cancelled))
}

fn exchange(
    at_port: &AtPort,
    command: &str,
    timeout_secs: u64,
    cancelled: Option<&std::sync::atomic::AtomicBool>,
) -> Result<String, String> {
    let port = at_port.probe().ok_or("no serial port found")?;
    if cancelled.is_some_and(|flag| flag.load(std::sync::atomic::Ordering::Acquire)) {
        return Err("exchange_cancelled".into());
    }
    let script = format!(
        "cat {p} & PID=$! ; sleep 0.3 ; echo -e '{cmd}\\r' > {p} ; sleep {t} ; kill $PID 2>/dev/null",
        p = port,
        cmd = command,
        t = timeout_secs
    );
    let output = Command::new("sh")
        .args(["-c", &script])
        .output()
        .map_err(|e| format!("failed to open port: {e}"))?;
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn cancelled_exchange_does_not_wait_for_the_port_owner() {
        let _owner = lock_port();
        let cancelled = std::sync::atomic::AtomicBool::new(true);
        assert_eq!(
            send_cancellable(&AtPort::new(), "ATD123;", 5, &cancelled).unwrap_err(),
            "exchange_cancelled"
        );
    }

    /// Tests run in parallel and another test may be inside `send` for a
    /// few microseconds, so poll rather than demand the lock is free *now*.
    fn lock_is_free() -> bool {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if AT_LOCK.try_lock().is_ok() {
                return true;
            }
            if Instant::now() > deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// On a dev box none of `PORTS` exist, so `send` fails in `probe()` via
    /// the `?` early return; the lock guard must still be dropped so the next
    /// exchange (and a competing thread) can proceed.
    #[test]
    fn send_releases_lock_on_early_return() {
        let port = AtPort::new();
        assert!(send(&port, "AT", 1).is_err());
        assert!(lock_is_free(), "AT_LOCK still held after send");
        assert!(send(&port, "AT", 1).is_err());
        assert!(port.detect().is_none());
        assert!(lock_is_free(), "AT_LOCK still held after detect");
    }

    #[test]
    fn concurrent_senders_do_not_deadlock() {
        let port = std::sync::Arc::new(AtPort::new());
        let handles: Vec<_> = (0..4)
            .map(|_| {
                let port = std::sync::Arc::clone(&port);
                std::thread::spawn(move || send(&port, "AT", 1).is_err())
            })
            .collect();
        for h in handles {
            assert!(h.join().unwrap());
        }
        assert!(lock_is_free());
    }
}
