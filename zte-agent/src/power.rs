use crate::event_bus::EventBus;
use serde_json::{json, Value};
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;

pub const RESUMED: &str = "zte_agent.resumed";
const LOCK_NAME: &str = "openu60-notification-recovery";
const RECOVERY_WINDOW: Duration = Duration::from_secs(30);
const CALL_HEARTBEAT: Duration = Duration::from_secs(5);
const LEASE_WINDOW: Duration = Duration::from_secs(10);
const SUSPEND_THRESHOLD: Duration = Duration::from_millis(500);

fn clock(id: libc::clockid_t) -> Result<Duration, &'static str> {
    let mut value = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(id, &mut value) } != 0
        || value.tv_sec < 0
        || !(0..1_000_000_000).contains(&value.tv_nsec)
    {
        return Err("power_clock_unavailable");
    }
    Ok(Duration::new(value.tv_sec as u64, value.tv_nsec as u32))
}

/// Linux BOOTTIME includes system suspend; the host build uses its monotonic
/// clock because it does not run the router's suspend recovery service.
pub fn boot_time() -> Result<Duration, &'static str> {
    #[cfg(target_os = "linux")]
    {
        clock(libc::CLOCK_BOOTTIME)
    }
    #[cfg(not(target_os = "linux"))]
    {
        clock(libc::CLOCK_MONOTONIC)
    }
}

fn clocks() -> Result<(Duration, Duration), &'static str> {
    let before = clock(libc::CLOCK_MONOTONIC)?;
    let boot = boot_time()?;
    let after = clock(libc::CLOCK_MONOTONIC)?;
    clock_sample(before, boot, after)
}

fn clock_sample(
    before: Duration,
    boot: Duration,
    after: Duration,
) -> Result<(Duration, Duration), &'static str> {
    let elapsed = after.checked_sub(before).ok_or("power_clock_regressed")?;
    // A thread preempted between these reads cannot locate the BOOTTIME sample
    // closely enough. Retry instead of mistaking that scheduling gap for sleep.
    if elapsed > Duration::from_millis(50) {
        return Err("power_clock_sample_delayed");
    }
    let monotonic = before + elapsed / 2;
    Ok((boot, monotonic))
}

#[derive(Default)]
struct SuspendDetector {
    offset: Option<Duration>,
}
impl SuspendDetector {
    fn sample(&mut self, boot: Duration, monotonic: Duration) -> Result<bool, &'static str> {
        // Clock reads are sequential, so a sub-millisecond negative initial
        // offset on a host is sampling jitter rather than a suspended interval.
        let offset = match boot.checked_sub(monotonic) {
            Some(value) => value,
            None if monotonic - boot < SUSPEND_THRESHOLD => Duration::ZERO,
            None => return Err("invalid_power_clocks"),
        };
        let resumed = match self.offset {
            Some(previous) if previous > offset && previous - offset > SUSPEND_THRESHOLD => {
                return Err("power_clock_regressed")
            }
            Some(previous) => offset.saturating_sub(previous) >= SUSPEND_THRESHOLD,
            None => false,
        };
        self.offset = Some(offset);
        Ok(resumed)
    }
}

#[derive(Default)]
struct Holds {
    recovery: Option<Duration>,
    notification: Option<Duration>,
    call: Option<Duration>,
}
impl Holds {
    fn until(&self) -> Option<Duration> {
        [self.recovery, self.notification, self.call]
            .into_iter()
            .flatten()
            .max()
    }
}

pub struct Recovery {
    holds: Mutex<Holds>,
    resumed: watch::Sender<u64>,
}
impl Recovery {
    pub fn new() -> Self {
        let (resumed, _) = watch::channel(0);
        Self {
            holds: Mutex::new(Holds::default()),
            resumed,
        }
    }
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.resumed.subscribe()
    }
    pub fn notification(&self) -> Result<(), &'static str> {
        self.holds.lock().unwrap().notification = Some(boot_time()? + RECOVERY_WINDOW);
        Ok(())
    }
    pub fn call(&self, active: bool) -> Result<(), &'static str> {
        self.holds.lock().unwrap().call = if active {
            Some(boot_time()? + CALL_HEARTBEAT)
        } else {
            None
        };
        Ok(())
    }
    pub fn start(self: &Arc<Self>, events: mpsc::Receiver<Value>, bus: Arc<EventBus>) {
        let recovery = self.clone();
        crate::system::spawn_named("wake-recovery", move || {
            let mut cycle = RecoveryCycle::default();
            let mut error = None;
            loop {
                let event = match events.recv_timeout(Duration::from_millis(250)) {
                    Ok(event) => Some(event),
                    Err(mpsc::RecvTimeoutError::Timeout) => None,
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        if let Err(code) = cycle.lease.update(Duration::ZERO, None, write_lock) {
                            eprintln!("[wake-recovery] {code}");
                        }
                        eprintln!("[wake-recovery] power_event_channel_closed");
                        return;
                    }
                };
                let outcome = cycle.step(&recovery, &bus, event.as_ref(), clocks, write_lock);
                if outcome.as_ref().err().copied() != error {
                    error = outcome.err();
                    if let Some(code) = error {
                        eprintln!("[wake-recovery] {code}");
                    }
                }
            }
        });
    }
}

#[derive(Default)]
struct RecoveryCycle {
    detector: SuspendDetector,
    lease: Lease,
    pending_firmware_wake: bool,
}
impl RecoveryCycle {
    fn step(
        &mut self,
        recovery: &Recovery,
        bus: &EventBus,
        event: Option<&Value>,
        sample: impl FnOnce() -> Result<(Duration, Duration), &'static str>,
        write: impl FnMut(bool, Duration) -> Result<(), &'static str>,
    ) -> Result<(), &'static str> {
        // The event has already left the channel. Retain it across a failed
        // clock sample until consumers have received the recovery notification.
        self.pending_firmware_wake |= event.is_some_and(|event| event["action"] == "mode_power_on");
        let (now, monotonic) = sample()?;
        let resumed = self.detector.sample(now, monotonic)? || self.pending_firmware_wake;
        if resumed {
            recovery.holds.lock().unwrap().recovery = Some(now + RECOVERY_WINDOW);
        }
        let until = recovery.holds.lock().unwrap().until();
        // Acquire before waking the consumers. A failed lock is
        // visible, but must not suppress reconnection or SMS replay.
        let held = self.lease.update(now, until, write);
        if resumed {
            recovery
                .resumed
                .send_modify(|generation| *generation = generation.wrapping_add(1));
            bus.publish(RESUMED, &json!({"resumed":true}));
            self.pending_firmware_wake = false;
            eprintln!("[wake-recovery] resumed; refreshing signaling and SMS");
        }
        held
    }
}

#[derive(Default)]
struct Lease {
    held: bool,
    renew_at: Duration,
}
impl Lease {
    fn update(
        &mut self,
        now: Duration,
        until: Option<Duration>,
        mut write: impl FnMut(bool, Duration) -> Result<(), &'static str>,
    ) -> Result<(), &'static str> {
        match until.filter(|until| *until > now) {
            Some(until) if !self.held || now >= self.renew_at => {
                let duration = (until - now).min(LEASE_WINDOW);
                write(true, duration)?;
                self.held = true;
                self.renew_at = now + duration / 2;
            }
            None if self.held => {
                write(false, Duration::ZERO)?;
                self.held = false;
            }
            _ => {}
        }
        Ok(())
    }
}
fn write_lock(hold: bool, duration: Duration) -> Result<(), &'static str> {
    let path = if hold {
        "/sys/power/wake_lock"
    } else {
        "/sys/power/wake_unlock"
    };
    // A timed kernel lease expires even after SIGKILL. The firmware's external
    // wakelock RPC instead keeps a service-owned fd until explicitly destroyed.
    let value = if hold {
        format!("{LOCK_NAME} {}\n", duration.as_nanos())
    } else {
        format!("{LOCK_NAME}\n")
    };
    OpenOptions::new()
        .write(true)
        .open(path)
        .and_then(|mut file| file.write_all(value.as_bytes()))
        .map_err(|_| {
            if hold {
                "recovery_wakelock_failed"
            } else {
                "recovery_wakeunlock_failed"
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn secs(value: u64) -> Duration {
        Duration::from_secs(value)
    }
    #[test]
    fn firmware_wake_survives_a_failed_clock_sample_and_is_published_once() {
        let bus = EventBus::new();
        let events = bus.subscribe(RESUMED);
        let recovery = Recovery::new();
        let mut resumed = recovery.subscribe();
        let mut cycle = RecoveryCycle::default();
        let event = json!({"action":"mode_power_on"});
        assert_eq!(
            cycle.step(
                &recovery,
                &bus,
                Some(&event),
                || Err("power_clock_sample_delayed"),
                |_, _| Ok(())
            ),
            Err("power_clock_sample_delayed")
        );
        assert!(events.try_recv().is_err());
        assert!(!resumed.has_changed().unwrap());
        cycle
            .step(
                &recovery,
                &bus,
                None,
                || Ok((secs(100), secs(100))),
                |_, _| Ok(()),
            )
            .unwrap();
        assert_eq!(events.try_recv().unwrap()["resumed"], true);
        assert_eq!(*resumed.borrow_and_update(), 1);
        cycle
            .step(
                &recovery,
                &bus,
                None,
                || Ok((secs(101), secs(101))),
                |_, _| Ok(()),
            )
            .unwrap();
        assert!(events.try_recv().is_err());
        assert!(!resumed.has_changed().unwrap());
    }
    #[test]
    fn resume_requires_time_spent_suspended_not_a_scheduling_delay() {
        let mut detector = SuspendDetector::default();
        assert!(!detector.sample(secs(100), secs(80)).unwrap());
        assert!(!detector.sample(secs(190), secs(170)).unwrap());
        assert!(detector.sample(secs(250), secs(171)).unwrap());
        assert!(!detector.sample(secs(251), secs(172)).unwrap());
        assert_eq!(
            detector.sample(secs(251), secs(180)),
            Err("power_clock_regressed")
        );
    }
    #[test]
    fn delayed_clock_reads_are_retried_instead_of_reporting_a_false_resume() {
        assert_eq!(
            clock_sample(secs(10), secs(20), secs(20)),
            Err("power_clock_sample_delayed")
        );
        let (boot, monotonic) =
            clock_sample(secs(10), secs(40), secs(10) + Duration::from_micros(4)).unwrap();
        let mut detector = SuspendDetector::default();
        assert!(!detector.sample(secs(9), secs(9)).unwrap());
        assert!(detector.sample(boot, monotonic).unwrap());
    }
    #[test]
    fn sampling_jitter_and_the_detection_boundary_are_distinct() {
        let mut detector = SuspendDetector::default();
        assert!(!detector
            .sample(secs(1), secs(1) + Duration::from_micros(2))
            .unwrap());
        for (millis, expected) in [(499, false), (500, true), (501, true)] {
            let mut detector = SuspendDetector::default();
            assert!(!detector.sample(secs(1), secs(1)).unwrap());
            assert_eq!(
                detector
                    .sample(secs(2) + Duration::from_millis(millis), secs(2))
                    .unwrap(),
                expected
            );
        }
        assert_eq!(
            SuspendDetector::default().sample(secs(1), secs(3)),
            Err("invalid_power_clocks")
        );
    }
    #[test]
    fn a_call_heartbeat_cannot_leave_a_permanent_wakelock_after_worker_failure() {
        let holds = Holds {
            recovery: None,
            notification: None,
            call: Some(secs(5)),
        };
        let mut lease = Lease::default();
        let mut writes = Vec::new();
        let mut write = |hold, duration| {
            writes.push((hold, duration));
            Ok(())
        };
        lease.update(secs(0), holds.until(), &mut write).unwrap();
        lease.update(secs(1), holds.until(), &mut write).unwrap();
        lease.update(secs(3), holds.until(), &mut write).unwrap();
        lease.update(secs(5), holds.until(), &mut write).unwrap();
        assert_eq!(
            writes,
            vec![(true, secs(5)), (true, secs(2)), (false, Duration::ZERO)]
        );
    }
    #[test]
    fn long_recovery_is_renewed_in_bounded_leases_and_release_failures_retry() {
        let mut lease = Lease::default();
        let mut writes = Vec::new();
        lease
            .update(secs(0), Some(secs(30)), |hold, duration| {
                writes.push((hold, duration));
                Ok(())
            })
            .unwrap();
        lease
            .update(secs(5), Some(secs(30)), |hold, duration| {
                writes.push((hold, duration));
                Ok(())
            })
            .unwrap();
        assert_eq!(writes, vec![(true, secs(10)), (true, secs(10))]);
        assert_eq!(
            lease.update(secs(31), None, |_, _| Err("write_failed")),
            Err("write_failed")
        );
        let mut released = false;
        lease
            .update(secs(32), None, |hold, _| {
                released = !hold;
                Ok(())
            })
            .unwrap();
        assert!(released);
        assert!(!lease.held);
    }
}
