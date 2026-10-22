use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::process::Command;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

const PORTS: &[&str] = &[
    // Factory USB bridges consume replies on mdm0 and mdm1. mdm2 is the
    // independent command channel on MU5250; keep older nodes for other models.
    "/dev/at_mdm2",
    "/dev/at_mdm1",
    "/dev/at_mdm0",
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
    exchange(at_port, command, timeout_secs, None, None)
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
    send_cancellable_inner(at_port, command, timeout_secs, cancelled, None)
}

pub fn send_cancellable_tracked(
    at_port: &AtPort,
    command: &str,
    timeout_secs: u64,
    cancelled: &std::sync::atomic::AtomicBool,
    submitted: &std::sync::atomic::AtomicBool,
) -> Result<String, String> {
    send_cancellable_inner(at_port, command, timeout_secs, cancelled, Some(submitted))
}
fn send_cancellable_inner(
    at_port: &AtPort,
    command: &str,
    timeout_secs: u64,
    cancelled: &std::sync::atomic::AtomicBool,
    submitted: Option<&std::sync::atomic::AtomicBool>,
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
    exchange(at_port, command, timeout_secs, Some(cancelled), submitted)
}

fn exchange(
    at_port: &AtPort,
    command: &str,
    timeout_secs: u64,
    cancelled: Option<&std::sync::atomic::AtomicBool>,
    submitted: Option<&std::sync::atomic::AtomicBool>,
) -> Result<String, String> {
    let port = at_port.probe().ok_or("no serial port found")?;
    if cancelled.is_some_and(|flag| flag.load(std::sync::atomic::Ordering::Acquire)) {
        return Err("exchange_cancelled".into());
    }
    if let Some(cancelled) = cancelled {
        // Call control needs the command's final result promptly. Legacy SMS/USSD
        // callers also collect asynchronous responses and retain their own window.
        let mut stream = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_CLOEXEC)
            .open(&port)
            .map_err(|_| "call_port_open")?;
        if cancelled.load(std::sync::atomic::Ordering::Acquire) {
            return Err("exchange_cancelled".into());
        }
        if let Some(submitted) = submitted {
            submitted.store(true, std::sync::atomic::Ordering::Release);
        }
        stream
            .write_all(format!("{command}\r").as_bytes())
            .map_err(|error| format!("call_port_write: {error}"))?;
        // The modem driver rejects nonblocking writes; only its reply reader
        // uses O_NONBLOCK, after the complete command has been submitted.
        let flags = unsafe { libc::fcntl(stream.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(stream.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err("call_port_flags".into());
        }
        return read_call_response(&mut stream, Duration::from_secs(timeout_secs));
    }
    let script = format!(
        "cat {p} & PID=$! ; sleep 0.3 ; echo -e '{cmd}\\r' > {p} ; sleep {t} ; kill $PID 2>/dev/null",
        p = port,
        cmd = command,
        t = timeout_secs
    );
    if let Some(submitted) = submitted {
        submitted.store(true, std::sync::atomic::Ordering::Release);
    }
    let output = Command::new("sh")
        .args(["-c", &script])
        .output()
        .map_err(|e| format!("failed to open port: {e}"))?;
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn terminal_end(bytes: &[u8]) -> Option<usize> {
    let mut end = 0;
    for line in bytes.split_inclusive(|b| matches!(b, b'\r' | b'\n')) {
        end += line.len();
        if !line.last().is_some_and(|b| matches!(b, b'\r' | b'\n')) {
            break;
        }
        let line = String::from_utf8_lossy(line);
        let line = line.trim();
        if matches!(line, "OK" | "ERROR" | "NO CARRIER" | "NO ANSWER" | "BUSY")
            || line.starts_with("+CME ERROR:")
            || line.starts_with("+CMS ERROR:")
        {
            return Some(end);
        }
    }
    None
}

fn read_call_response(
    stream: &mut (impl Read + AsRawFd),
    timeout: Duration,
) -> Result<String, String> {
    let deadline = Instant::now() + timeout;
    let mut response = Vec::new();
    let mut buffer = [0u8; 4096];
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let mut descriptor = libc::pollfd {
            fd: stream.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe {
            libc::poll(
                &mut descriptor,
                1,
                remaining.as_millis().clamp(1, i32::MAX as u128) as i32,
            )
        };
        if ready < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err("call_port_poll".into());
        }
        if ready == 0 {
            break;
        }
        if descriptor.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
            return Err("call_port_poll".into());
        }
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                if response.len() + count > 65536 {
                    return Err("call_reply_too_large".into());
                }
                response.extend_from_slice(&buffer[..count]);
                if let Some(end) = terminal_end(&response) {
                    response.truncate(end);
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                ) => {}
            Err(_) => return Err("call_port_read".into()),
        }
    }
    Ok(String::from_utf8_lossy(&response).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn call_reply_returns_on_final_result_without_waiting_for_the_window() {
        let (mut reader, mut writer) = std::os::unix::net::UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        let (finished, completion) = std::sync::mpsc::channel();
        let sender = std::thread::spawn(move || {
            writer.write_all(b"\r\n+CLCC: 1,1,0,1,0\r\nO").unwrap();
            std::thread::sleep(Duration::from_millis(20));
            writer.write_all(b"K\r\nRING\r\n").unwrap();
            completion.recv_timeout(Duration::from_secs(2)).unwrap();
        });
        let started = Instant::now();
        let response = read_call_response(&mut reader, Duration::from_secs(2)).unwrap();
        assert!(response.trim_end().ends_with("OK"));
        assert!(!response.contains("RING"));
        assert!(started.elapsed() < Duration::from_secs(1));
        finished.send(()).unwrap();
        sender.join().unwrap();
    }
    #[test]
    fn partial_call_reply_and_modem_errors_remain_distinct() {
        let (mut reader, mut writer) = std::os::unix::net::UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        writer.write_all(b"+CLCC: 1,0,2,0,0\r\n").unwrap();
        let response = read_call_response(&mut reader, Duration::from_millis(20)).unwrap();
        assert!(!response.contains("OK"));
        assert_eq!(terminal_end(b"+CME ERROR: 3\r\nRING\r\n"), Some(14));
        assert_eq!(terminal_end(b"+CLCC: 1,0,0,0,0,\"OK\",129\r\n"), None);
        assert_eq!(terminal_end(b"O"), None);
    }

    #[test]
    fn cancellation_while_waiting_for_the_port_cannot_commit_a_dial() {
        let owner = lock_port();
        let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let committed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (flag, marker) = (cancelled.clone(), committed.clone());
        let task = std::thread::spawn(move || {
            send_cancellable_tracked(&AtPort::new(), "ATD123;", 5, &flag, &marker)
        });
        std::thread::sleep(Duration::from_millis(40));
        cancelled.store(true, std::sync::atomic::Ordering::Release);
        assert_eq!(task.join().unwrap().unwrap_err(), "exchange_cancelled");
        assert!(!committed.load(std::sync::atomic::Ordering::Acquire));
        drop(owner);
    }
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
