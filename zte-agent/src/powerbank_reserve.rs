use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::event_bus::EventBus;
use crate::remote_calling::storage::{private_read, private_write};

pub const CHANGED: &str = "openu60.power_reserve.changed";
const SETTINGS: &str = "/data/openu60-power/reserve.json";
const SAMPLE_WINDOW: Duration = Duration::from_secs(60);
const MIN_SAMPLE_SPAN: Duration = Duration::from_secs(10);

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub min_capacity_percent: Option<u8>,
    pub reserve_minutes: Option<u16>,
}
impl Policy {
    fn validate(&self) -> Result<(), String> {
        if self.min_capacity_percent.is_some_and(|v| !(1..=100).contains(&v)) {
            return Err("Minimum battery must be between 1 and 100 percent".into());
        }
        if self.reserve_minutes.is_some_and(|v| !(1..=2880).contains(&v)) {
            return Err("Router runtime reserve must be between 1 and 2880 minutes".into());
        }
        Ok(())
    }
    fn enabled(&self) -> bool { self.min_capacity_percent.is_some() || self.reserve_minutes.is_some() }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum StopReason { MinimumBattery, ReservedRuntime, LoadUnavailable, TelemetryUnavailable }

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Stop {
    reason: StopReason,
    at: Option<u64>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Saved {
    version: u8,
    policy: Policy,
    pending_stop: Option<StopReason>,
    last_stop: Option<Stop>,
}
impl Default for Saved {
    fn default() -> Self {
        Self { version: 1, policy: Policy::default(), pending_stop: None, last_stop: None }
    }
}

struct Reading {
    capacity: u8,
    energy_wh: Option<f64>,
    router_load_w: Option<f64>,
}

trait Effects: Send {
    fn enabled(&mut self) -> Result<bool, String>;
    fn set_enabled(&mut self, enabled: bool) -> Result<(), String>;
    fn sample(&mut self) -> Result<Reading, String>;
    fn hold_awake(&mut self, active: bool) -> Result<(), String>;
}

#[derive(Default)]
struct DeviceEffects { awake: bool }
impl Effects for DeviceEffects {
    fn enabled(&mut self) -> Result<bool, String> { crate::usb::powerbank_enabled() }
    fn set_enabled(&mut self, enabled: bool) -> Result<(), String> { crate::usb::apply_powerbank_state(enabled) }
    fn sample(&mut self) -> Result<Reading, String> {
        let b = crate::system::read_battery()?;
        let capacity = u8::try_from(b.capacity).ok().filter(|v| *v <= 100)
            .ok_or("Battery percentage is unavailable")?;
        if b.voltage_uv <= 0 { return Err("Battery voltage is unavailable".into()); }
        let battery_w = b.voltage_uv as f64 * b.current_ua as f64 / 1e12;
        let energy_wh = b.charge_full_uah.filter(|v| *v > 0)
            .map(|full| full as f64 * b.voltage_uv as f64 / 1e12 * capacity as f64 / 100.0);
        let router_load_w = if b.usb.role.as_deref() == Some("sink") && b.usb.online == Some(true) {
            b.usb.input_voltage_uv.filter(|v| *v > 0)
                .zip(b.usb.input_current_ua.filter(|v| *v >= 0))
                .map(|(v, i)| v as f64 * i as f64 / 1e12 - battery_w)
        } else if b.current_ua <= -50000 {
            Some(-battery_w)
        } else { None }.filter(|w| w.is_finite() && *w >= 0.05);
        Ok(Reading { capacity, energy_wh, router_load_w })
    }
    fn hold_awake(&mut self, active: bool) -> Result<(), String> {
        use std::io::Write;
        if !active && !self.awake { return Ok(()); }
        let path = if active { "/sys/power/wake_lock" } else { "/sys/power/wake_unlock" };
        let value = if active { "openu60-power-reserve 45000000000\n" } else { "openu60-power-reserve\n" };
        std::fs::OpenOptions::new().write(true).open(path)
            .and_then(|mut f| f.write_all(value.as_bytes()))
            .map_err(|e| format!("Power reserve wake lease: {e}"))?;
        self.awake = active;
        Ok(())
    }
}

#[derive(Clone)]
struct Baseline { watts: f64, at: Duration }

struct Inner {
    file: PathBuf,
    saved: Option<Saved>,
    error: Option<String>,
    effects: Box<dyn Effects>,
    samples: VecDeque<(Duration, f64)>,
    baseline: Option<Baseline>,
    output: Option<bool>,
    energy_wh: Option<f64>,
}
impl Inner {
    fn load(file: &Path) -> Result<Saved, String> {
        if !file.try_exists().map_err(|e| format!("Power reserve settings: {e}"))? {
            return Ok(Saved::default());
        }
        let saved: Saved = serde_json::from_slice(&private_read(file)?)
            .map_err(|_| "Invalid power reserve settings")?;
        if saved.version != 1 { return Err("Unsupported power reserve settings version".into()); }
        saved.policy.validate()?;
        Ok(saved)
    }
    fn save(&mut self, next: Saved) -> Result<(), String> {
        private_write(&self.file, &serde_json::to_vec(&next).map_err(|e| e.to_string())?)
            .map_err(|e| format!("Could not save power reserve: {e}"))?;
        self.saved = Some(next);
        Ok(())
    }
    fn policy(&self) -> Result<Policy, String> {
        self.saved.as_ref().map(|s| s.policy.clone()).ok_or("Power reserve settings are unavailable".into())
    }
    fn baseline_ready(&self, now: Duration) -> bool {
        self.baseline.as_ref().is_some_and(|b| self.output == Some(true)
            || now.checked_sub(b.at).is_some_and(|age| age <= SAMPLE_WINDOW))
    }
    fn runtime(&self, now: Duration) -> Option<f64> {
        if !self.baseline_ready(now) { return None; }
        self.energy_wh.zip(self.baseline.as_ref()).map(|(energy, b)| energy / b.watts * 60.0)
            .filter(|v| v.is_finite() && *v >= 0.0)
    }
    fn status(&self, now: Duration) -> Value {
        json!({"policy":self.saved.as_ref().map(|s| &s.policy),
            "baseline_ready":self.baseline_ready(now),
            "router_load_w":self.baseline.as_ref().filter(|_| self.baseline_ready(now)).map(|b| b.watts),
            "router_runtime_minutes":self.runtime(now),
            "pending_stop":self.saved.as_ref().and_then(|s| s.pending_stop.as_ref()),
            "last_stop":self.saved.as_ref().and_then(|s| s.last_stop.as_ref()),
            "error":self.error})
    }
    fn sample_load(&mut self, now: Duration, reading: &Reading) {
        self.samples.retain(|(at, _)| now.checked_sub(*at).is_some_and(|age| age <= SAMPLE_WINDOW));
        if let Some(watts) = reading.router_load_w {
            if self.samples.back().is_none_or(|(at, _)| now.saturating_sub(*at) >= Duration::from_secs(4)) {
                self.samples.push_back((now, watts));
            }
        }
        if reading.router_load_w.is_some() && self.samples.len() >= 3
            && self.samples.back().unwrap().0.saturating_sub(self.samples.front().unwrap().0) >= MIN_SAMPLE_SPAN {
            self.baseline = Some(Baseline {
                watts: self.samples.iter().map(|(_, w)| w).sum::<f64>() / self.samples.len() as f64,
                at: self.samples.back().unwrap().0,
            });
        }
    }
    fn reason(&self, policy: &Policy, reading: &Reading, now: Duration) -> Option<StopReason> {
        if policy.min_capacity_percent.is_some_and(|min| reading.capacity <= min) {
            return Some(StopReason::MinimumBattery);
        }
        if let Some(minutes) = policy.reserve_minutes {
            return match self.runtime(now) {
                Some(remaining) if remaining <= minutes as f64 => Some(StopReason::ReservedRuntime),
                None => Some(StopReason::LoadUnavailable),
                _ => None,
            };
        }
        None
    }
    fn stop(&mut self, reason: StopReason) -> Result<(), String> {
        let mut next = self.saved.clone().ok_or("Power reserve settings are unavailable")?;
        if next.pending_stop.is_none() {
            next.pending_stop = Some(reason.clone());
            next.last_stop = Some(Stop { reason, at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH).ok().map(|v| v.as_secs()) });
            // The retry intent survives an agent restart before the BSP has acknowledged off.
            if let Err(error) = self.save(next) {
                let off = self.effects.set_enabled(false);
                return Err(format!("{error}; emergency USB stop: {}", off.err().unwrap_or_else(|| "confirmed".into())));
            }
        }
        self.effects.set_enabled(false)?;
        self.output = Some(false);
        self.effects.hold_awake(false)?;
        let mut next = self.saved.clone().unwrap();
        next.pending_stop = None;
        self.save(next)
    }
    fn tick(&mut self, now: Duration) -> Result<(), String> {
        let policy = match self.policy() {
            Ok(p) => p,
            Err(error) => {
                // Corrupt settings remain visible; never silently turn protection off.
                if self.effects.enabled()? { self.effects.set_enabled(false)?; }
                return Err(error);
            }
        };
        if let Some(reason) = self.saved.as_ref().and_then(|s| s.pending_stop.clone()) {
            let lease = self.effects.hold_awake(true);
            self.stop(reason)?;
            return lease;
        }
        if !policy.enabled() { return self.effects.hold_awake(false); }
        let active = match self.effects.enabled() {
            Ok(active) => active,
            Err(error) => { self.stop(StopReason::TelemetryUnavailable)?; return Err(error); }
        };
        if active && self.output != Some(true) && !self.baseline_ready(now) {
            self.baseline = None;
        }
        self.output = Some(active);
        if self.output == Some(true) {
            if let Err(error) = self.effects.hold_awake(true) {
                self.stop(StopReason::TelemetryUnavailable)?;
                return Err(error);
            }
        } else { self.effects.hold_awake(false)?; }
        let reading = match self.effects.sample() {
            Ok(value) => value,
            Err(error) => {
                self.energy_wh = None;
                if self.output == Some(true) { self.stop(StopReason::TelemetryUnavailable)?; }
                return Err(error);
            }
        };
        self.energy_wh = reading.energy_wh;
        if self.output == Some(false) {
            if policy.reserve_minutes.is_some() { self.sample_load(now, &reading); }
            self.effects.hold_awake(policy.reserve_minutes.is_some() && !self.baseline_ready(now))?;
        } else if let Some(reason) = self.reason(&policy, &reading, now) { self.stop(reason)?; }
        Ok(())
    }
    fn request_enabled(&mut self, enabled: bool, now: Duration) -> Result<(), String> {
        if enabled {
            let policy = self.policy()?;
            if policy.enabled() {
                let reading = self.effects.sample()?;
                self.energy_wh = reading.energy_wh;
                if let Some(reason) = self.reason(&policy, &reading, now) {
                    return Err(match reason {
                        StopReason::MinimumBattery => "Minimum battery reserve reached",
                        StopReason::ReservedRuntime => "Router runtime reserve reached",
                        _ => "Router load is still being measured. Leave USB output off for at least 10 seconds and retry",
                    }.into());
                }
                self.effects.hold_awake(true)?;
            }
            let mut next = self.saved.clone().unwrap();
            next.pending_stop = None;
            next.last_stop = None;
            self.save(next)?;
        }
        self.effects.set_enabled(enabled)?;
        self.output = Some(enabled);
        if !enabled {
            self.effects.hold_awake(false)?;
            if let Some(mut next) = self.saved.clone() {
                next.pending_stop = None;
                self.save(next)?;
            }
        }
        Ok(())
    }
}

pub struct PowerbankReserve {
    inner: Mutex<Inner>,
    bus: OnceLock<Arc<EventBus>>,
}
impl PowerbankReserve {
    pub fn new() -> Self { Self::at(Path::new(SETTINGS), Box::<DeviceEffects>::default()) }
    fn at(file: &Path, effects: Box<dyn Effects>) -> Self {
        let (saved, error) = match Inner::load(file) { Ok(s) => (Some(s), None), Err(e) => (None, Some(e)) };
        Self { inner: Mutex::new(Inner { file: file.into(), saved, error, effects,
            samples: VecDeque::new(), baseline: None, output: None, energy_wh: None }), bus: OnceLock::new() }
    }
    pub fn status(&self) -> Value {
        match crate::power::boot_time() {
            Ok(now) => self.inner.lock().unwrap().status(now),
            Err(e) => json!({"policy":null,"baseline_ready":false,"error":e}),
        }
    }
    fn notify(&self) {
        if let Some(bus) = self.bus.get() { bus.publish(CHANGED, &json!({"changed":true})); }
    }
    pub fn configure(&self, bytes: &[u8]) -> (u16, Value) {
        if !serde_json::from_slice::<Value>(bytes).ok().is_some_and(|v| v.get("min_capacity_percent").is_some()
            && v.get("reserve_minutes").is_some()) {
            return (400, json!({"ok":false,"error":"Both reserve settings must be provided; use null to disable a limit"}));
        }
        let policy: Policy = match serde_json::from_slice(bytes) {
            Ok(v) => v,
            Err(_) => return (400, json!({"ok":false,"error":"Invalid power reserve settings"})),
        };
        if let Err(error) = policy.validate() { return (400, json!({"ok":false,"error":error})); }
        let mut inner = self.inner.lock().unwrap();
        let needs_baseline = policy.reserve_minutes.is_some()
            && !inner.saved.as_ref().is_some_and(|s| s.policy.reserve_minutes.is_some());
        let mut next = inner.saved.clone().unwrap_or_default();
        next.policy = policy;
        if let Err(error) = inner.save(next) { return (503, json!({"ok":false,"error":error})); }
        if needs_baseline { inner.baseline = None; inner.samples.clear(); }
        inner.error = None;
        drop(inner);
        self.notify();
        (200, json!({"ok":true,"data":self.status()}))
    }
    pub fn set_enabled(&self, enabled: bool) -> (u16, Value) {
        let now = match crate::power::boot_time() {
            Ok(v) => v, Err(e) => return (503, json!({"ok":false,"error":e})),
        };
        let mut inner = self.inner.lock().unwrap();
        let result = inner.request_enabled(enabled, now);
        inner.error = result.as_ref().err().cloned();
        drop(inner);
        self.notify();
        match result {
            Ok(()) => (200, json!({"ok":true,"data":{"state":i32::from(enabled)}})),
            Err(error) => (503, json!({"ok":false,"error":error})),
        }
    }
    pub fn start(self: &Arc<Self>, bus: Arc<EventBus>, events: mpsc::Receiver<Value>, cache: Arc<crate::cache::UbusCache>) {
        self.bus.set(bus).unwrap_or_else(|_| panic!("power reserve already started"));
        let owner = self.clone();
        crate::system::spawn_named("powerbank-reserve", move || {
            loop {
                let delay = {
                    let mut inner = owner.inner.lock().unwrap();
                    let before = inner.output;
                    let result = match crate::power::boot_time() {
                        Ok(now) => inner.tick(now),
                        Err(error) => {
                            if inner.policy().is_ok_and(|p| p.enabled()) {
                                if let Err(stop_error) = inner.stop(StopReason::TelemetryUnavailable) {
                                    eprintln!("[powerbank-reserve] {stop_error}");
                                }
                            }
                            Err(error.into())
                        }
                    };
                    if result.as_ref().err() != inner.error.as_ref() {
                        if let Err(error) = &result { eprintln!("[powerbank-reserve] {error}"); }
                    }
                    inner.error = result.err();
                    if before != inner.output { cache.invalidate(crate::cache::CHARGER); }
                    if inner.saved.as_ref().is_some_and(|s| !s.policy.enabled() && s.pending_stop.is_none()) {
                        Duration::from_secs(600)
                    } else if inner.output == Some(false) && inner.baseline.is_some() { Duration::from_secs(15) }
                    else { Duration::from_secs(5) }
                };
                match events.recv_timeout(delay) {
                    Ok(_) | Err(mpsc::RecvTimeoutError::Timeout) => {},
                    Err(mpsc::RecvTimeoutError::Disconnected) => { eprintln!("[powerbank-reserve] event channel closed"); return; }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Hardware {
        enabled: bool,
        capacity: u8,
        energy: Option<f64>,
        load: Option<f64>,
        fail_stop: bool,
        fail_sample: bool,
        commands: Vec<bool>,
    }
    struct Fake(Arc<Mutex<Hardware>>);
    impl Effects for Fake {
        fn enabled(&mut self) -> Result<bool, String> { Ok(self.0.lock().unwrap().enabled) }
        fn set_enabled(&mut self, enabled: bool) -> Result<(), String> {
            let mut hw = self.0.lock().unwrap();
            hw.commands.push(enabled);
            if !enabled && hw.fail_stop { return Err("BSP stop failed".into()); }
            hw.enabled = enabled;
            Ok(())
        }
        fn sample(&mut self) -> Result<Reading, String> {
            let hw = self.0.lock().unwrap();
            if hw.fail_sample { return Err("Fuel gauge unavailable".into()); }
            Ok(Reading { capacity: hw.capacity, energy_wh: hw.energy, router_load_w: hw.load })
        }
        fn hold_awake(&mut self, _: bool) -> Result<(), String> { Ok(()) }
    }
    struct Fixture {
        root: PathBuf,
        owner: PowerbankReserve,
        hw: Arc<Mutex<Hardware>>,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("openu60-reserve-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&root).unwrap();
            let hw = Arc::new(Mutex::new(Hardware { enabled: false, capacity: 80, energy: Some(20.0),
                load: Some(2.0), fail_stop: false, fail_sample: false, commands: vec![] }));
            let owner = PowerbankReserve::at(&root.join("power/reserve.json"), Box::new(Fake(hw.clone())));
            Self { root, owner, hw }
        }
        fn policy(&self, min: Option<u8>, minutes: Option<u16>) {
            let response = self.owner.configure(&serde_json::to_vec(&Policy { min_capacity_percent: min, reserve_minutes: minutes }).unwrap());
            assert_eq!(response.0, 200, "{}", response.1);
        }
        fn tick(&self, seconds: u64) -> Result<(), String> { self.owner.inner.lock().unwrap().tick(Duration::from_secs(seconds)) }
        fn enable(&self, seconds: u64) -> Result<(), String> {
            self.owner.inner.lock().unwrap().request_enabled(true, Duration::from_secs(seconds))
        }
        fn warm(&self) { for seconds in [0, 5, 10] { self.tick(seconds).unwrap(); } }
    }
    impl Drop for Fixture {
        fn drop(&mut self) { std::fs::remove_dir_all(&self.root).unwrap(); }
    }

    #[test]
    fn upgrade_defaults_leave_existing_output_untouched() {
        let f = Fixture::new();
        f.hw.lock().unwrap().enabled = true;
        f.tick(0).unwrap();
        assert!(f.hw.lock().unwrap().enabled);
        assert!(f.hw.lock().unwrap().commands.is_empty());
        assert!(!f.root.join("power/reserve.json").exists());
    }

    #[test]
    fn restart_without_router_baseline_stops_a_time_protected_session() {
        let f = Fixture::new();
        f.policy(None, Some(120));
        f.warm();
        f.enable(11).unwrap();
        let restart = PowerbankReserve::at(&f.root.join("power/reserve.json"), Box::new(Fake(f.hw.clone())));
        restart.inner.lock().unwrap().tick(Duration::from_secs(20)).unwrap();
        assert!(!f.hw.lock().unwrap().enabled);
        assert_eq!(restart.inner.lock().unwrap().saved.as_ref().unwrap().last_stop.as_ref().unwrap().reason, StopReason::LoadUnavailable);
    }

    #[test]
    fn threshold_still_attempts_emergency_off_when_stop_intent_cannot_be_saved() {
        let f = Fixture::new();
        f.policy(Some(20), None);
        f.enable(0).unwrap();
        f.hw.lock().unwrap().capacity = 10;
        std::fs::rename(f.root.join("power"), f.root.join("old-power")).unwrap();
        std::fs::write(f.root.join("power"), b"storage unavailable").unwrap();
        assert!(f.tick(5).is_err());
        assert!(!f.hw.lock().unwrap().enabled);
    }

    #[test]
    fn minimum_battery_stops_at_boundary_without_automatically_resuming() {
        let f = Fixture::new();
        f.policy(Some(20), None);
        f.enable(0).unwrap();
        f.hw.lock().unwrap().capacity = 21;
        f.tick(5).unwrap();
        assert!(f.hw.lock().unwrap().enabled);
        f.hw.lock().unwrap().capacity = 20;
        f.tick(10).unwrap();
        assert!(!f.hw.lock().unwrap().enabled);
        assert!(f.enable(11).unwrap_err().contains("Minimum battery"));
        f.hw.lock().unwrap().capacity = 80;
        f.tick(15).unwrap();
        assert_eq!(f.hw.lock().unwrap().commands, vec![true, false]);
        assert_eq!(f.owner.inner.lock().unwrap().saved.as_ref().unwrap().last_stop.as_ref().unwrap().reason, StopReason::MinimumBattery);
    }

    #[test]
    fn runtime_reserve_uses_router_load_before_output_not_connected_device_load() {
        let f = Fixture::new();
        f.policy(Some(20), Some(120));
        f.warm();
        f.enable(11).unwrap();
        f.hw.lock().unwrap().load = Some(20.0);
        f.tick(15).unwrap();
        assert!(f.hw.lock().unwrap().enabled);
        assert_eq!(f.owner.inner.lock().unwrap().runtime(Duration::from_secs(15)), Some(600.0));
        f.hw.lock().unwrap().energy = Some(4.0);
        f.tick(20).unwrap();
        assert!(!f.hw.lock().unwrap().enabled);
        assert_eq!(f.owner.inner.lock().unwrap().saved.as_ref().unwrap().last_stop.as_ref().unwrap().reason, StopReason::ReservedRuntime);
    }

    #[test]
    fn runtime_cannot_start_without_a_recent_measured_baseline() {
        let f = Fixture::new();
        f.policy(None, Some(60));
        assert!(f.enable(0).is_err());
        f.tick(0).unwrap();
        f.tick(5).unwrap();
        assert!(f.enable(6).is_err());
        f.tick(10).unwrap();
        assert!(f.owner.inner.lock().unwrap().baseline_ready(Duration::from_secs(10)));
        assert!(f.enable(100).is_err());
        assert!(f.hw.lock().unwrap().commands.is_empty());
        // A firmware toggle must not make an expired baseline valid again.
        f.hw.lock().unwrap().enabled = true;
        f.tick(100).unwrap();
        assert!(!f.hw.lock().unwrap().enabled);
    }

    #[test]
    fn failed_stop_is_durable_and_retried_after_agent_restart() {
        let f = Fixture::new();
        f.policy(Some(20), None);
        { let mut hw = f.hw.lock().unwrap(); hw.enabled = true; hw.capacity = 10; hw.fail_stop = true; }
        assert!(f.tick(0).is_err());
        let saved = Inner::load(&f.root.join("power/reserve.json")).unwrap();
        assert_eq!(saved.pending_stop, Some(StopReason::MinimumBattery));
        f.hw.lock().unwrap().fail_stop = false;
        let restart = PowerbankReserve::at(&f.root.join("power/reserve.json"), Box::new(Fake(f.hw.clone())));
        restart.inner.lock().unwrap().tick(Duration::from_secs(5)).unwrap();
        assert!(!f.hw.lock().unwrap().enabled);
        let saved = Inner::load(&f.root.join("power/reserve.json")).unwrap();
        assert_eq!(saved.pending_stop, None);
        assert_eq!(saved.last_stop.unwrap().reason, StopReason::MinimumBattery);
    }

    #[test]
    fn missing_battery_telemetry_stops_protected_output() {
        let f = Fixture::new();
        f.policy(Some(20), None);
        f.enable(0).unwrap();
        f.hw.lock().unwrap().fail_sample = true;
        assert!(f.tick(5).is_err());
        assert!(!f.hw.lock().unwrap().enabled);
        assert_eq!(f.owner.inner.lock().unwrap().saved.as_ref().unwrap().last_stop.as_ref().unwrap().reason, StopReason::TelemetryUnavailable);
    }

    #[test]
    fn invalid_policy_does_not_replace_settings_and_a_save_failure_cannot_enable_output() {
        let f = Fixture::new();
        f.policy(Some(20), Some(60));
        let file = f.root.join("power/reserve.json");
        let before = std::fs::read(&file).unwrap();
        for input in [r#"{}"#, r#"{"min_capacity_percent":0,"reserve_minutes":null}"#,
            r#"{"min_capacity_percent":101,"reserve_minutes":null}"#,
            r#"{"min_capacity_percent":null,"reserve_minutes":2881}"#,
            r#"{"min_capacity_percent":null,"reserve_minutes":0}"#] {
            assert_eq!(f.owner.configure(input.as_bytes()).0, 400);
            assert_eq!(std::fs::read(&file).unwrap(), before);
        }
        let blocked = f.root.join("not-a-directory");
        std::fs::write(&blocked, b"not settings").unwrap();
        let owner = PowerbankReserve::at(&blocked.join("reserve.json"), Box::new(Fake(f.hw.clone())));
        assert!(owner.inner.lock().unwrap().request_enabled(true, Duration::ZERO).is_err());
        assert!(f.hw.lock().unwrap().commands.is_empty());
    }
}
