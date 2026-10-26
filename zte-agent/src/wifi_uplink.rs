use crate::remote_calling::storage::{private_read, private_write};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::Read;
use std::io::Write;
use std::net::Ipv4Addr;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixDatagram, UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

const DIRECTORY: &str = "/data/openu60-wifi";
const NETWORK: &str = "openu60_wifi";
// Apple's success page is reachable from mainland China as well as elsewhere, unlike gstatic.
const PROBE: &str = "https://www.apple.com/library/test/success.html";
const UI_SOCKET: &str = "/data/openu60-wifi/ui.sock";

pub fn ui_status_cli() -> Result<(), String> {
    let mut stream =
        UnixStream::connect(UI_SOCKET).map_err(|_| "Local Wi-Fi service is unavailable")?;
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .map_err(|_| "Cannot set local status deadline")?;
    stream
        .write_all(br#"{"action":"status"}"#)
        .map_err(|_| "Cannot request local Wi-Fi status")?;
    stream
        .shutdown(std::net::Shutdown::Write)
        .map_err(|_| "Cannot finish local Wi-Fi request")?;
    let mut response = String::new();
    stream
        .take(131073)
        .read_to_string(&mut response)
        .map_err(|_| "Cannot read local Wi-Fi status")?;
    if response.len() > 131072 {
        return Err("Local Wi-Fi status is too large".into());
    }
    let parsed: Value =
        serde_json::from_str(&response).map_err(|_| "Invalid local Wi-Fi status")?;
    println!("{}", parsed);
    Ok(())
}

#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum Mode {
    #[default]
    Hotspot,
    Repeater,
}
#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Debug)]
enum Band {
    #[default]
    #[serde(rename = "2g")]
    Two,
    #[serde(rename = "5g")]
    Five,
}
impl Band {
    fn interface(self) -> &'static str {
        match self {
            Self::Two => "wlan0",
            Self::Five => "wlan2",
        }
    }
    fn hotspot(self) -> &'static str {
        match self {
            Self::Two => "wlan2",
            Self::Five => "wlan0",
        }
    }
    fn contains(self, frequency: u32) -> bool {
        match self {
            Self::Two => (2400..2500).contains(&frequency),
            Self::Five => (4900..5900).contains(&frequency),
        }
    }
    fn frequencies(self) -> String {
        let frequencies: Vec<u32> = match self {
            Self::Two => (2412..=2472).step_by(5).collect(),
            Self::Five => (5180..=5320)
                .step_by(20)
                .chain((5500..=5720).step_by(20))
                .chain((5745..=5885).step_by(20))
                .collect(),
        };
        frequencies
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(" ")
    }
}
#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum Security {
    Auto,
    Open,
    #[default]
    Wpa2,
    Wpa3,
    Mixed,
}
#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum MacMode {
    #[default]
    Factory,
    Random,
    Clone,
}

// This is the supplicant client's private profile, never an API response or log value.
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Config {
    mode: Mode,
    band: Band,
    ssid: String,
    security: Security,
    password: String,
    mac_mode: MacMode,
    clone_mac: String,
    #[serde(default)]
    random_mac: String,
    ttl: Option<u8>,
}
impl Config {
    fn redacted(&self) -> Value {
        json!({"mode":self.mode,"band":self.band,"ssid":self.ssid,"security":self.security,
            "has_password":!self.password.is_empty(),"mac_mode":self.mac_mode,
            "clone_mac":self.clone_mac,"ttl":self.ttl})
    }
    fn validate(&self) -> Result<(), &'static str> {
        if self.mode == Mode::Hotspot {
            return Ok(());
        }
        if self.ssid.is_empty() || self.ssid.len() > 32 || self.ssid.chars().any(char::is_control) {
            return Err("SSID must contain 1–32 bytes and no control characters");
        }
        if self.security != Security::Open
            && !(self.security == Security::Auto && self.password.is_empty())
        {
            let psk = (8..=63).contains(&self.password.len())
                || (self.security == Security::Wpa2
                    && self.password.len() == 64
                    && self.password.bytes().all(|b| b.is_ascii_hexdigit()));
            if !psk || self.password.chars().any(char::is_control) {
                return Err(
                    "Enter a valid Wi-Fi password (8–63 bytes, or a 64-digit WPA2 hexadecimal key)",
                );
            }
        }
        if self.mac_mode == MacMode::Clone && !valid_mac(&self.clone_mac) {
            return Err("Enter the unicast MAC address to clone");
        }
        if self.ttl == Some(0) {
            return Err("TTL must be between 1 and 255");
        }
        if self.mac_mode == MacMode::Random && !valid_mac(&self.random_mac) {
            return Err("Invalid saved random MAC address");
        }
        Ok(())
    }
    fn supplicant(&self, control: &Path) -> String {
        let mut text = format!(
            "ctrl_interface={}\nupdate_config=0\nnetwork={{\nssid={}\nfreq_list={}\nscan_ssid=1\n",
            control.display(),
            hex(self.ssid.as_bytes()),
            self.band.frequencies()
        );
        match self.security {
            Security::Open | Security::Auto if self.password.is_empty() => {
                text.push_str("key_mgmt=NONE\n")
            }
            Security::Open => text.push_str("key_mgmt=NONE\n"),
            Security::Wpa2 => {
                let key = if self.password.len() == 64 {
                    self.password.clone()
                } else {
                    quote(&self.password)
                };
                text.push_str(&format!("key_mgmt=WPA-PSK\nproto=RSN\npsk={key}\n"));
            }
            Security::Wpa3 => text.push_str(&format!(
                "key_mgmt=SAE\nieee80211w=2\nsae_password={}\n",
                quote(&self.password)
            )),
            Security::Mixed | Security::Auto => text.push_str(&format!(
                "key_mgmt=WPA-PSK SAE\nieee80211w=1\npsk={}\nsae_password={}\n",
                quote(&self.password),
                quote(&self.password)
            )),
        }
        text.push_str("}\n");
        text
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Change {
    mode: Mode,
    band: Option<Band>,
    ssid: Option<String>,
    security: Option<Security>,
    password: Option<String>,
    mac_mode: Option<MacMode>,
    clone_mac: Option<String>,
    ttl: Option<u8>,
}
impl Change {
    fn merge(self, prior: &Config) -> Result<Config, &'static str> {
        let mut config = prior.clone();
        config.mode = self.mode;
        if let Some(band) = self.band {
            config.band = band;
        }
        if let Some(ssid) = self.ssid {
            config.ssid = ssid;
        }
        if let Some(security) = self.security {
            config.security = security;
        }
        if let Some(password) = self.password {
            config.password = password;
        } else if config.ssid != prior.ssid || config.security != prior.security {
            config.password.clear();
        }
        if config.security == Security::Open {
            config.password.clear();
        }
        if let Some(mode) = self.mac_mode {
            config.mac_mode = mode;
        }
        if let Some(mac) = self.clone_mac {
            config.clone_mac = mac.to_ascii_lowercase();
        }
        if config.mode != Mode::Hotspot {
            config.ttl = self.ttl;
        }
        if config.mac_mode == MacMode::Random
            && (prior.mac_mode != MacMode::Random
                || prior.ssid != config.ssid
                || config.random_mac.is_empty())
        {
            let mut bytes = *uuid::Uuid::new_v4().as_bytes();
            bytes[0] = (bytes[0] | 2) & 0xfe;
            config.random_mac = bytes[..6]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<Vec<_>>()
                .join(":");
        }
        config.validate()?;
        Ok(config)
    }
}

#[derive(Clone, Deserialize, Serialize)]
struct Baseline {
    mac_2g: String,
    mac_5g: String,
    ipv6_2g: String,
    ipv6_5g: String,
}
#[derive(Clone, Deserialize, Serialize)]
struct Record {
    config: Config,
    baseline: Option<Baseline>,
    operation_id: String,
    phase: String,
    error: Option<String>,
    #[serde(default)]
    policy_owned: bool,
}
impl Default for Record {
    fn default() -> Self {
        Self {
            config: Config::default(),
            baseline: None,
            operation_id: String::new(),
            phase: "hotspot".into(),
            error: None,
            policy_owned: false,
        }
    }
}
#[derive(Clone, Serialize, Debug)]
struct Network {
    ssid: String,
    bssid: String,
    frequency: u32,
    signal: i32,
    security: String,
    supported: bool,
}
struct Snapshot {
    record: Record,
    load_error: Option<String>,
    busy: bool,
    scans: Vec<Network>,
    scan_error: Option<String>,
    ipv4: Option<String>,
    portal_url: Option<String>,
    connectivity: String,
    runtime_error: Option<String>,
    clock_error: Option<String>,
    clock_attempt: Option<Instant>,
    clock_baseline: Option<(Instant, SystemTime)>,
}
enum Action {
    Apply,
    Resume,
    Scan(Band),
    Portal,
}
pub struct WifiUplink {
    panda: Mutex<Option<Arc<crate::panda::PandaRouter>>>,
    connection: Mutex<Option<Arc<crate::remote_calling::RemoteCalling>>>,
    shared: Mutex<Snapshot>,
    tx: mpsc::Sender<Action>,
    rx: Mutex<Option<mpsc::Receiver<Action>>>,
    directory: PathBuf,
}

impl WifiUplink {
    pub fn new() -> Self {
        Self::at(Path::new(DIRECTORY))
    }
    fn at(directory: &Path) -> Self {
        let file = directory.join("profile.private.json");
        let loaded = match std::fs::symlink_metadata(&file) {
            Ok(_) => private_read(&file).and_then(|data| {
                serde_json::from_slice::<Record>(&data)
                    .map_err(|_| "Invalid saved Wi-Fi profile".into())
            }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Record::default()),
            Err(_) => Err("Cannot read saved Wi-Fi profile".into()),
        };
        let (record, load_error) = match loaded {
            Ok(r) => (r, None),
            Err(e) => (Record::default(), Some(e)),
        };
        let (tx, rx) = mpsc::channel();
        Self {
            panda: Mutex::new(None),
            connection: Mutex::new(None),
            shared: Mutex::new(Snapshot {
                record,
                load_error,
                busy: false,
                scans: vec![],
                scan_error: None,
                ipv4: None,
                portal_url: None,
                connectivity: "unknown".into(),
                runtime_error: None,
                clock_error: None,
                clock_attempt: None,
                clock_baseline: None,
            }),
            tx,
            rx: Mutex::new(Some(rx)),
            directory: directory.into(),
        }
    }
    pub fn attach_connection(&self, manager: Arc<crate::remote_calling::RemoteCalling>) {
        *self.connection.lock().unwrap() = Some(manager);
    }

    pub fn attach_panda(&self, panda: Arc<crate::panda::PandaRouter>) {
        *self.panda.lock().unwrap() = Some(panda);
    }
    fn save(&self, record: &Record) -> Result<(), String> {
        private_write(
            &self.directory.join("profile.private.json"),
            &serde_json::to_vec(record).map_err(|_| "Cannot encode Wi-Fi profile")?,
        )
    }
    pub fn status(&self) -> (u16, Value) {
        let s = self.shared.lock().unwrap();
        (
            200,
            json!({"ok":true,"data":{"config":s.record.config.redacted(),"operation_id":s.record.operation_id,
            "phase":if s.load_error.is_some() {"failed"} else {&s.record.phase},"busy":s.busy,
            "error":s.load_error.as_ref().or(s.record.error.as_ref()).or(s.runtime_error.as_ref()).or(s.clock_error.as_ref()),"networks":s.scans,"scan_error":s.scan_error,
            "ipv4":s.ipv4,"portal_url":s.portal_url,"connectivity":s.connectivity}}),
        )
    }
    pub fn edit_hotspot(&self, edit: impl FnOnce() -> (u16, Value)) -> (u16, Value) {
        {
            let mut s = self.shared.lock().unwrap();
            if s.busy {
                return failure(409, "Wait for the current Wi-Fi operation to finish");
            }
            s.busy = true;
        }
        let result = edit();
        let mut s = self.shared.lock().unwrap();
        s.busy = false;
        if result.0 < 300
            && s.record.config.mode != Mode::Hotspot
            && s.record.phase != "failed"
            && result.1["data"]["hot"] != true
            && result.1["data"]["note"] != "no changes"
        {
            let mut record = s.record.clone();
            record.operation_id = uuid::Uuid::new_v4().to_string();
            record.phase = "pending".into();
            record.error = None;
            if let Err(error) = self.save(&record) {
                return failure(503, &format!("Hotspot settings applied, but Wi-Fi uplink restart could not be saved: {error}"));
            }
            s.record = record;
            s.busy = true;
            if self.tx.send(Action::Apply).is_err() {
                s.busy = false;
                return failure(
                    503,
                    "Hotspot settings applied; uplink restart requires restarting the agent",
                );
            }
        }
        result
    }
    pub fn apply(&self, bytes: &[u8]) -> (u16, Value) {
        let change: Change = match serde_json::from_slice(bytes) {
            Ok(c) => c,
            Err(_) => return failure(400, "Invalid Wi-Fi mode settings"),
        };
        let mut s = self.shared.lock().unwrap();
        if s.busy {
            return failure(409, "A Wi-Fi operation is already running");
        }
        if s.load_error.is_some() {
            return failure(
                503,
                "Saved Wi-Fi profile is unreadable; restore it before changing modes",
            );
        }
        let config = match change.merge(&s.record.config) {
            Ok(c) => c,
            Err(e) => return failure(400, e),
        };
        let record = Record {
            config,
            baseline: s.record.baseline.clone(),
            operation_id: uuid::Uuid::new_v4().to_string(),
            phase: "pending".into(),
            error: None,
            policy_owned: s.record.policy_owned,
        };
        if let Err(e) = self.save(&record) {
            return failure(503, &e);
        }
        s.record = record;
        s.busy = true;
        if self.tx.send(Action::Apply).is_err() {
            s.busy = false;
            return failure(
                503,
                "Wi-Fi worker is unavailable; the saved change will be reconciled after restart",
            );
        }
        (
            202,
            json!({"ok":true,"data":{"operation_id":s.record.operation_id,"phase":"pending"}}),
        )
    }
    pub fn scan(&self, bytes: &[u8]) -> (u16, Value) {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Request {
            band: Band,
        }
        let request: Request = match serde_json::from_slice(bytes) {
            Ok(r) => r,
            Err(_) => return failure(400, "Select a scan band"),
        };
        let mut s = self.shared.lock().unwrap();
        if s.busy {
            return failure(409, "A Wi-Fi operation is already running");
        }
        s.busy = true;
        s.scan_error = None;
        if self.tx.send(Action::Scan(request.band)).is_err() {
            s.busy = false;
            return failure(503, "Wi-Fi worker is unavailable");
        }
        (202, json!({"ok":true,"data":{"scanning":true}}))
    }
    pub fn portal(&self) -> (u16, Value) {
        let mut s = self.shared.lock().unwrap();
        if s.busy {
            return failure(409, "A Wi-Fi operation is already running");
        }
        if s.record.config.mode == Mode::Hotspot || s.ipv4.is_none() {
            return failure(409, "Connect the Wi-Fi uplink first");
        }
        s.busy = true;
        if self.tx.send(Action::Portal).is_err() {
            s.busy = false;
            return failure(503, "Wi-Fi worker is unavailable");
        }
        (202, json!({"ok":true,"data":{"checking":true}}))
    }
    pub fn resume(&self) -> Result<(), &'static str> {
        self.tx.send(Action::Resume).map_err(|_| "wifi_worker_unavailable_after_wake")
    }
    pub fn start(self: &Arc<Self>) {
        let Some(rx) = self.rx.lock().unwrap().take() else {
            return;
        };
        let service = Arc::clone(self);
        if let Err(error) = self.start_ui() {
            eprintln!("[wifi-ui] {error}");
        }
        crate::system::spawn_named("wifi-uplink", move || {
            let recover = {
                let s = service.shared.lock().unwrap();
                s.load_error.is_none()
                    && s.record.config.mode != Mode::Hotspot
                    && s.record.phase != "failed"
            };
            if recover {
                service.execute_apply();
            }
            let mut last_probe = Instant::now();
            loop {
                match rx.recv_timeout(Duration::from_secs(10)) {
                    Ok(Action::Apply) => service.execute_apply(),
                    Ok(Action::Resume) => {
                        let active = {
                            let s = service.shared.lock().unwrap();
                            s.record.config.mode != Mode::Hotspot
                                && s.record.phase != "failed" && !s.busy
                        };
                        if active {
                            service.repair_interface();
                            service.refresh_link();
                            service.check_portal();
                            service.synchronize_clock();
                            last_probe = Instant::now();
                        }
                    }
                    Ok(Action::Scan(band)) => {
                        let result = service.execute_scan(band);
                        let mut s = service.shared.lock().unwrap();
                        match result {
                            Ok(networks) => {
                                s.scans = networks;
                                s.scan_error = None;
                            }
                            Err(e) => s.scan_error = Some(e),
                        }
                        s.busy = false;
                    }
                    Ok(Action::Portal) => {
                        service.check_portal();
                        service.shared.lock().unwrap().busy = false;
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        let (active, every) = {
                            let s = service.shared.lock().unwrap();
                            (
                                s.record.config.mode != Mode::Hotspot
                                    && s.record.phase != "failed"
                                    && !s.busy,
                                probe_interval(&s.connectivity),
                            )
                        };
                        if active {
                            service.repair_interface();
                            service.refresh_link();
                            if last_probe.elapsed() >= every {
                                service.check_portal();
                                service.synchronize_clock();
                                last_probe = Instant::now();
                            }
                        }
                    }
                }
            }
        });
    }

    fn start_ui(self: &Arc<Self>) -> Result<(), String> {
        match std::fs::create_dir(&self.directory) {
            Ok(()) => {
                std::fs::set_permissions(&self.directory, std::fs::Permissions::from_mode(0o700))
                    .map_err(|_| "Cannot protect the local Wi-Fi directory")?
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => return Err("Cannot create the local Wi-Fi directory".into()),
        }
        let directory = std::fs::symlink_metadata(&self.directory)
            .map_err(|_| "Cannot inspect the local Wi-Fi directory")?;
        if !directory.is_dir()
            || directory.uid() != unsafe { libc::geteuid() }
            || directory.mode() & 0o077 != 0
        {
            return Err("The local Wi-Fi directory must be private and owned by the agent".into());
        }
        let path = self.directory.join("ui.sock");
        match std::fs::symlink_metadata(&path) {
            Ok(meta)
                if meta.file_type().is_socket() && meta.uid() == unsafe { libc::geteuid() } =>
            {
                std::fs::remove_file(&path)
                    .map_err(|_| "Cannot remove the old local Wi-Fi socket")?;
            }
            Ok(_) => return Err("Unexpected local Wi-Fi socket file".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("Cannot inspect the local Wi-Fi socket".into()),
        }
        let listener =
            UnixListener::bind(&path).map_err(|_| "Cannot bind the local Wi-Fi socket")?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "Cannot protect the local Wi-Fi socket")?;
        let service = Arc::clone(self);
        crate::system::try_spawn_named("wifi-ui", move || {
            for stream in listener.incoming() {
                let mut stream = match stream {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("[wifi-ui] accept failed: {e}");
                        continue;
                    }
                };
                if let Err(e) = service.ui_connection(&mut stream) {
                    eprintln!("[wifi-ui] {e}");
                }
            }
        })
        .map_err(|_| "Cannot start the local Wi-Fi listener")?;
        Ok(())
    }

    fn ui_connection(&self, stream: &mut UnixStream) -> Result<(), &'static str> {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .map_err(|_| "Cannot set local read deadline")?;
        stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .map_err(|_| "Cannot set local write deadline")?;
        let mut bytes = vec![];
        Read::take(&mut *stream, 8193)
            .read_to_end(&mut bytes)
            .map_err(|_| "Incomplete local Wi-Fi request")?;
        let (status, mut response) = self.ui_request(&bytes);
        response["status"] = json!(status);
        let response =
            serde_json::to_vec(&response).map_err(|_| "Cannot encode local Wi-Fi response")?;
        stream
            .write_all(&response)
            .map_err(|_| "Cannot send local Wi-Fi response")
    }

    fn ui_request(&self, bytes: &[u8]) -> (u16, Value) {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Request {
            action: String,
            #[serde(default)]
            body: Value,
        }
        if bytes.len() > 8192 {
            return failure(413, "Local Wi-Fi request is too large");
        }
        let request: Request = match serde_json::from_slice(bytes) {
            Ok(r) => r,
            Err(_) => return failure(400, "Invalid local Wi-Fi request"),
        };
        let body = match serde_json::to_vec(&request.body) {
            Ok(b) => b,
            Err(_) => return failure(400, "Invalid local Wi-Fi parameters"),
        };
        match request.action.as_str() {
            "panda-status" | "panda-action" => match self.panda.lock().unwrap().as_ref() {
                Some(panda) if request.action == "panda-status" => panda.native_status(),
                Some(panda) => panda.native_action(&body),
                None => failure(503, "PandaFan is unavailable"),
            },
            "connection" => match self.connection.lock().unwrap().as_ref() {
                Some(manager) => (200, manager.connection_info()),
                None => failure(503, "Remote access is unavailable"),
            },
            "status" => self.status(),
            "calls" => match self.connection.lock().unwrap().as_ref() {
                Some(manager)=>match manager.recordings.snapshot(false,0) {
                    Ok(data)=>(200,json!({"ok":true,"data":data})),
                    Err(error)=>failure(503,&error),
                },
                None=>failure(503,"Calling service is unavailable"),
            },
            "scan" => self.scan(&body),
            "apply" => self.apply(&body),
            "portal" => self.portal(),
            _ => failure(400, "Unknown local Wi-Fi action"),
        }
    }
    fn transition(&self, phase: &str, error: Option<String>) -> Result<(), String> {
        let mut s = self.shared.lock().unwrap();
        let mut record = s.record.clone();
        record.phase = phase.into();
        record.error = error;
        self.save(&record)?;
        s.record = record;
        Ok(())
    }
    fn execute_apply(&self) {
        let (config, baseline) = {
            let mut s = self.shared.lock().unwrap();
            s.busy = true;
            s.ipv4 = None;
            s.portal_url = None;
            s.connectivity = "unknown".into();
            s.runtime_error = None;
            (s.record.config.clone(), s.record.baseline.clone())
        };
        let result = (|| {
            self.transition("connecting", None)?;
            wait_wireless_interfaces()?;
            let restoring = baseline.is_some();
            let baseline = match baseline {
                Some(b) => b,
                None => {
                    let b = Baseline::capture()?;
                    let mut s = self.shared.lock().unwrap();
                    let mut r = s.record.clone();
                    r.baseline = Some(b.clone());
                    self.save(&r)?;
                    s.record = r;
                    b
                }
            };
            if restoring {
                self.restore(&baseline)?;
            }
            if config.mode == Mode::Hotspot {
                self.transition("hotspot", None)?;
                return Ok(());
            }
            self.claim_policy()?;
            self.connect(&config)?;
            self.transition("connected", None)?;
            self.refresh_link();
            self.check_portal();
            self.synchronize_clock();
            Ok::<_, String>(())
        })();
        if let Err(error) = result {
            let baseline = self.shared.lock().unwrap().record.baseline.clone();
            let recovery = baseline.as_ref().map(|b| self.restore(b));
            let error = match recovery {
                Some(Err(e)) => format!("{error}. Hotspot recovery also failed: {e}"),
                Some(Ok(())) => format!("{error}. Restored hotspot mode"),
                None => format!("{error}. No wireless interfaces were changed"),
            };
            if let Err(e) = self.transition("failed", Some(error)) {
                let mut s = self.shared.lock().unwrap();
                s.record.phase = "failed".into();
                s.record.error = Some(format!(
                    "Wi-Fi operation failed; cannot save its outcome: {e}"
                ));
            }
        }
        self.shared.lock().unwrap().busy = false;
    }
    fn restore(&self, baseline: &Baseline) -> Result<(), String> {
        if self.shared.lock().unwrap().record.policy_owned {
            policy_cleanup()?;
        }
        let control = self.directory.join("control");
        for iface in ["wlan0", "wlan2"] {
            if supplicant_control_active(&control.join(iface))? {
                run(
                    "wpa_cli",
                    &["-p", path(&control)?, "-i", iface, "terminate"],
                    3,
                )?;
            }
        }
        if json_command(
            "ubus",
            &[
                "-t",
                "3",
                "call",
                &format!("network.interface.{NETWORK}"),
                "status",
            ],
        )
        .is_ok()
        {
            run(
                "ubus",
                &[
                    "-t",
                    "3",
                    "call",
                    &format!("network.interface.{NETWORK}"),
                    "remove",
                ],
                4,
            )?;
        }
        firewall(None)?;
        for (iface, mac, ipv6) in [
            ("wlan0", &baseline.mac_2g, &baseline.ipv6_2g),
            ("wlan2", &baseline.mac_5g, &baseline.ipv6_5g),
        ] {
            run("ip", &["link", "set", iface, "down"], 3)?;
            run("iw", &["dev", iface, "set", "type", "__ap"], 3)?;
            run("ip", &["link", "set", iface, "address", mac], 3)?;
            std::fs::write(
                format!("/proc/sys/net/ipv6/conf/{iface}/disable_ipv6"),
                ipv6,
            )
            .map_err(|_| "Cannot restore hotspot IPv6 settings")?;
        }
        crate::system::arm_post_wifi_watchdog(Duration::from_secs(150));
        // A diff-based reload ignores our runtime-only station changes.
        run("/sbin/wifi", &["up"], 75)?;
        let deadline = Instant::now() + Duration::from_secs(90);
        loop {
            if ["wlan0", "wlan2"].iter().all(|iface| {
                run("iw", &["dev", iface, "info"], 3).is_ok_and(|v| v.contains("type AP"))
            }) {
                for (iface, value) in [("wlan0", &baseline.ipv6_2g), ("wlan2", &baseline.ipv6_5g)] {
                    std::fs::write(
                        format!("/proc/sys/net/ipv6/conf/{iface}/disable_ipv6"),
                        value,
                    )
                    .map_err(|_| "Cannot restore hotspot IPv6 settings")?;
                }
                let switch = run("uci", &["-q", "get", "wireless.zte_mbb.wifi_onoff"], 3)?;
                if switch.trim() == "1" {
                    for (radio, section, iface) in
                        [("wifi0", "main_2g", "wlan0"), ("wifi1", "main_5g", "wlan2")]
                    {
                        let radio_disabled = run(
                            "uci",
                            &["-q", "get", &format!("wireless.{radio}.disabled")],
                            3,
                        )?;
                        let ssid_disabled = run(
                            "uci",
                            &["-q", "get", &format!("wireless.{section}.disabled")],
                            3,
                        )?;
                        if radio_disabled.trim() == "0" && ssid_disabled.trim() == "0" {
                            wait_hotspot(iface)?;
                        }
                    }
                }
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err("Firmware did not restore its hotspot interfaces".into());
            }
            std::thread::sleep(Duration::from_millis(300));
        }
    }
    fn connect(&self, config: &Config) -> Result<(), String> {
        let iface = config.band.interface();
        for ap in ["wlan0", "wlan1", "wlan2", "wlan3"] {
            if config.mode == Mode::Repeater && ap == config.band.hotspot() {
                continue;
            }
            if Path::new(&format!("/sys/class/net/{ap}")).exists() {
                run("/etc/init.d/hostapd-daemon.init", &["stop", ap], 5)?;
                run("ip", &["link", "set", ap, "down"], 3)?;
            }
        }
        run("ip", &["link", "set", iface, "nomaster"], 3)?;
        run("iw", &["dev", iface, "set", "type", "managed"], 3)?;
        firewall(Some(config))?;
        let mac = match config.mac_mode {
            MacMode::Factory => None,
            MacMode::Clone => Some(config.clone_mac.clone()),
            MacMode::Random => Some(config.random_mac.clone()),
        };
        if let Some(mac) = mac {
            run("ip", &["link", "set", iface, "address", &mac], 3)?;
        }
        std::fs::write(format!("/proc/sys/net/ipv6/conf/{iface}/disable_ipv6"), "1")
            .map_err(|_| "Cannot disable unmanaged upstream IPv6")?;
        run("ip", &["link", "set", iface, "up"], 3)?;
        if config.mode == Mode::Repeater {
            let ap = config.band.hotspot();
            run("ip", &["link", "set", ap, "master", "br-lan"], 3)?;
            let ping = run(
                "hostapd_cli",
                &["-p", "/data/vendor/wifi/hostapd", "-i", ap, "ping"],
                3,
            );
            if !ping.is_ok_and(|v| v.trim() == "PONG") {
                run("ip", &["link", "set", ap, "up"], 3)?;
                run("/etc/init.d/hostapd-daemon.init", &["start", ap], 5)?;
            }
            wait_hotspot(ap)?;
        }
        let profile = self.directory.join("supplicant.private.conf");
        private_write(
            &profile,
            config
                .supplicant(&self.directory.join("control"))
                .as_bytes(),
        )?;
        run(
            "wpa_supplicant",
            &[
                "-B",
                "-Dnl80211",
                "-i",
                iface,
                "-c",
                path(&profile)?,
                "-P",
                path(&self.directory.join("supplicant.pid"))?,
            ],
            5,
        )?;
        let deadline = Instant::now() + Duration::from_secs(35);
        loop {
            let status = run(
                "wpa_cli",
                &[
                    "-p",
                    path(&self.directory.join("control"))?,
                    "-i",
                    iface,
                    "status",
                ],
                3,
            )?;
            if status.lines().any(|l| l == "wpa_state=COMPLETED") {
                break;
            }
            if Instant::now() >= deadline {
                return Err(
                    "Wi-Fi association timed out; check the network, password and selected band"
                        .into(),
                );
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        let params = json!({"name":NETWORK,"proto":"dhcp","ifname":iface,"defaultroute":true,"peerdns":true,"metric":10,"hostname":if config.mac_mode==MacMode::Clone {"*"} else {"OpenU60"}});
        let response = run(
            "ubus",
            &[
                "-t",
                "3",
                "call",
                "network",
                "add_dynamic",
                &params.to_string(),
            ],
            5,
        )?;
        // netifd's successful add_dynamic method has an empty ubus response.
        if !response.trim().is_empty() {
            let response: Value = serde_json::from_str(&response)
                .map_err(|_| "Invalid DHCP interface creation response")?;
            if response.get("error").is_some() {
                return Err("DHCP interface could not be created".into());
            }
        }
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let status = network_status()?;
            if status["up"] == true {
                validate_subnet(&status)?;
                firewall(Some(config))?;
                policy_routes(&status)?;
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err("The upstream Wi-Fi did not provide an IPv4 address".into());
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    }
    fn execute_scan(&self, band: Band) -> Result<Vec<Network>, String> {
        let iface = {
            let s = self.shared.lock().unwrap();
            if s.record.config.mode == Mode::Hotspot || s.record.phase == "failed" {
                "wlan2"
            } else {
                s.record.config.band.interface()
            }
        };
        // This qcacld firmware omits nearby BSS entries when given an explicit frequency list.
        let text = run("iw", &["dev", iface, "scan"], 15)?;
        Ok(parse_scan(&text, band))
    }
    fn claim_policy(&self) -> Result<(), String> {
        let mut s = self.shared.lock().unwrap();
        if s.record.policy_owned {
            return Ok(());
        }
        if run("ip", &["-4", "rule", "show"], 3)?
            .lines()
            .any(|line| line.trim_start().starts_with("10060:"))
            || policy_has_routes(&run("ip", &["-4", "route", "show", "table", "all"], 3)?)
        {
            return Err("Wi-Fi policy routing table is already in use".into());
        }
        let mut record = s.record.clone();
        record.policy_owned = true;
        self.save(&record)?;
        s.record = record;
        Ok(())
    }
    fn refresh_link(&self) {
        let config = self.shared.lock().unwrap().record.config.clone();
        let result = (|| {
            let status = network_status()?;
            if status["up"] == true {
                validate_subnet(&status)?;
                policy_routes(&status)?;
                if !firewall_present(&config)? {
                    firewall(Some(&config))?;
                }
            }
            Ok::<_, String>(status)
        })();
        let mut s = self.shared.lock().unwrap();
        match result {
            Ok(status) if status["up"] == true => {
                s.runtime_error = None;
                s.ipv4 = status["ipv4-address"][0]["address"]
                    .as_str()
                    .map(str::to_owned);
            }
            result => {
                s.ipv4 = None;
                s.portal_url = None;
                s.connectivity = "disconnected".into();
                s.runtime_error = result.err();
            }
        }
    }
    fn repair_interface(&self) {
        let (config, id) = {
            let s = self.shared.lock().unwrap();
            if s.busy || s.record.phase == "failed" {
                return;
            }
            (s.record.config.clone(), s.record.operation_id.clone())
        };
        if run("iw", &["dev", config.band.interface(), "info"], 3)
            .is_ok_and(|v| v.contains("type managed"))
        {
            return;
        }
        {
            let mut s = self.shared.lock().unwrap();
            if s.busy || s.record.operation_id != id {
                return;
            }
            s.busy = true;
        }
        self.execute_apply();
    }
    fn check_portal(&self) {
        let iface = {
            let s = self.shared.lock().unwrap();
            if s.ipv4.is_none() {
                return;
            }
            s.record.config.band.interface()
        };
        let result = probe_portal(iface);
        let mut s = self.shared.lock().unwrap();
        match result {
            Ok((state, url)) => {
                s.connectivity = state.into();
                s.portal_url = url;
            }
            Err(_) => {
                s.connectivity = "limited".into();
                s.portal_url = Some(PROBE.into());
            }
        }
    }

    fn synchronize_clock(&self) {
        {
            let mut s = self.shared.lock().unwrap();
            if s.connectivity != "online" || s.ipv4.is_none() {
                return;
            }
            if s.clock_attempt
                .is_some_and(|time| time.elapsed() < Duration::from_secs(60))
            {
                return;
            }
            if let Some((instant, wall)) = s.clock_baseline {
                let expected = wall + instant.elapsed();
                let now = SystemTime::now();
                let drift = now
                    .duration_since(expected)
                    .unwrap_or_else(|error| error.duration());
                if instant.elapsed() < Duration::from_secs(3600) && drift < Duration::from_secs(5) {
                    return;
                }
            }
            s.clock_attempt = Some(Instant::now());
        }
        let result = (|| {
            if run(
                "uci",
                &["-q", "get", "zwrt_zte_sntp.settings.time_set_mode"],
                3,
            )?
            .trim()
                != "auto"
            {
                return Err(
                    "Automatic time is disabled; correct the router clock in time settings".into(),
                );
            }
            let server = run("uci", &["-q", "get", "zwrt_zte_sntp.settings.server0"], 3)?;
            let server = server.trim();
            if server.is_empty()
                || server.starts_with('-')
                || server.chars().any(char::is_whitespace)
            {
                return Err("Invalid configured time server".into());
            }
            let status = network_status().unwrap_or(Value::Null);
            let addresses = resolve_time_server(server, &status, |name, dns| match dns {
                Some(dns) => run("nslookup", &[name, &dns.to_string()], 3),
                None => run("nslookup", &[name], 5),
            })?;
            let mut failure = "The configured time server did not reply";
            for address in addresses.into_iter().take(3) {
                match crate::wifi_time::query(address) {
                    Ok(time) => {
                        crate::wifi_time::set_utc(time)?;
                        return Ok::<_, String>(());
                    }
                    Err(error) => failure = error,
                }
            }
            Err(failure.into())
        })();
        let mut s = self.shared.lock().unwrap();
        match result {
            Ok(()) => {
                s.clock_error = None;
                s.clock_baseline = Some((Instant::now(), SystemTime::now()));
            }
            Err(error) => {
                s.clock_error = Some(format!(
                    "Wi-Fi is connected, but time synchronization failed: {error}"
                ));
            }
        }
    }
}

fn wait_wireless_interfaces() -> Result<(), String> {
    // rc.local starts the agent before the vendor WLAN driver creates its netdevs.
    let deadline = Instant::now() + Duration::from_secs(90);
    loop {
        if ["wlan0", "wlan2"]
            .iter()
            .all(|iface| Path::new("/sys/class/net").join(iface).exists())
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(
                "The firmware did not create both Wi-Fi interfaces within 90 seconds".into(),
            );
        }
        std::thread::sleep(Duration::from_millis(300));
    }
}

fn supplicant_control_active(socket: &Path) -> Result<bool, String> {
    let metadata = match std::fs::symlink_metadata(socket) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err("Cannot inspect the Wi-Fi control socket".into()),
    };
    if !metadata.file_type().is_socket() {
        return Err("The Wi-Fi control path is not a socket".into());
    }
    let probe = UnixDatagram::unbound().map_err(|_| "Cannot probe the Wi-Fi control socket")?;
    match probe.connect(socket) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::ConnectionRefused => {
            // /data survives reboot; a socket inode can outlive its daemon.
            // Only this worker starts the supplicant in this private directory.
            std::fs::remove_file(socket)
                .map_err(|_| "Cannot remove the stale Wi-Fi control socket")?;
            Ok(false)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("Cannot connect to the Wi-Fi control socket".into()),
    }
}

fn wait_hotspot(iface: &str) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(90);
    let mut enabled = false;
    loop {
        if Instant::now() >= deadline {
            return Err(
                "Hotspot did not become ready; check channel and regulatory settings".into(),
            );
        }
        // A persistent socket inode does not mean the newly started daemon is listening.
        let probe =
            UnixDatagram::unbound().map_err(|_| "Cannot probe the hotspot control socket")?;
        match probe.connect(Path::new("/data/vendor/wifi/hostapd").join(iface)) {
            Ok(()) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                ) =>
            {
                std::thread::sleep(Duration::from_millis(300));
                continue;
            }
            Err(_) => return Err("Cannot connect to the hotspot control socket".into()),
        }
        drop(probe);
        if !Path::new("/data/vendor/wifi/hostapd").join(iface).exists() {
            std::thread::sleep(Duration::from_millis(300));
            continue;
        }
        let status = run(
            "hostapd_cli",
            &["-p", "/data/vendor/wifi/hostapd", "-i", iface, "status"],
            3,
        )?;
        if status.lines().any(|l| l == "state=ENABLED") {
            return Ok(());
        }
        if !enabled && status.lines().any(|l| l == "state=DISABLED") {
            let result = run(
                "hostapd_cli",
                &["-p", "/data/vendor/wifi/hostapd", "-i", iface, "enable"],
                3,
            )?;
            if result.trim() != "OK" {
                return Err("Hotspot could not be enabled".into());
            }
            enabled = true;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

fn policy_cleanup() -> Result<(), String> {
    let rules = run("ip", &["-4", "rule", "show"], 3)?;
    if rules
        .lines()
        .any(|line| line.trim_start().starts_with("10060:") && line.contains("lookup 2060"))
    {
        run(
            "ip",
            &["-4", "rule", "del", "priority", "10060", "lookup", "2060"],
            3,
        )?;
    }
    // This firmware returns an error when flushing a table that has never had routes.
    if policy_has_routes(&run("ip", &["-4", "route", "show", "table", "all"], 3)?) {
        run("ip", &["-4", "route", "flush", "table", "2060"], 3)?;
    }
    Ok(())
}

fn policy_has_routes(routes: &str) -> bool {
    routes.lines().any(|line| {
        line.split_whitespace()
            .collect::<Vec<_>>()
            .windows(2)
            .any(|p| p == ["table", "2060"])
    })
}

fn connected_routes(text: &str) -> Result<Vec<(String, String)>, String> {
    let mut routes = vec![];
    for line in text.lines() {
        let parts: Vec<_> = line.split_whitespace().collect();
        if parts.contains(&"linkdown") {
            continue;
        }
        if parts.len() < 3 || parts[1] != "dev" {
            return Err("Unexpected connected route format".into());
        }
        let prefix = parts[0];
        let (address, mask) = prefix.split_once('/').unwrap_or((prefix, "32"));
        address
            .parse::<Ipv4Addr>()
            .map_err(|_| "Invalid connected IPv4 route")?;
        mask.parse::<u8>()
            .ok()
            .filter(|p| *p <= 32)
            .ok_or("Invalid connected IPv4 prefix")?;
        let iface = parts[2];
        if iface.is_empty()
            || iface.len() > 15
            || !iface
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-.:".contains(&b))
        {
            return Err("Invalid connected interface".into());
        }
        routes.push((prefix.to_owned(), iface.to_owned()));
    }
    Ok(routes)
}

fn policy_routes(status: &Value) -> Result<(), String> {
    let iface = status["l3_device"]
        .as_str()
        .ok_or("Missing Wi-Fi DHCP interface")?;
    if !["wlan0", "wlan2"].contains(&iface) {
        return Err("Unexpected Wi-Fi DHCP interface".into());
    }
    let gateway = status["route"]
        .as_array()
        .ok_or("Missing DHCP routes")?
        .iter()
        .find(|r| r["target"] == "0.0.0.0" && r["mask"] == 0)
        .and_then(|r| r["nexthop"].as_str())
        .ok_or("Upstream Wi-Fi did not provide a default gateway")?;
    gateway
        .parse::<Ipv4Addr>()
        .map_err(|_| "Invalid DHCP gateway")?;
    let routes = connected_routes(&run(
        "ip",
        &["-4", "route", "show", "table", "main", "scope", "link"],
        3,
    )?)?;
    for (prefix, dev) in routes {
        run(
            "ip",
            &[
                "-4", "route", "replace", &prefix, "dev", &dev, "table", "2060",
            ],
            3,
        )?;
    }
    // Keep a selected Wi-Fi source from silently falling through to the SIM when its lease disappears.
    run(
        "ip",
        &[
            "-4",
            "route",
            "replace",
            "unreachable",
            "default",
            "metric",
            "32767",
            "table",
            "2060",
        ],
        3,
    )?;
    run(
        "ip",
        &[
            "-4", "route", "replace", "default", "via", gateway, "dev", iface, "metric", "10",
            "table", "2060",
        ],
        3,
    )?;
    if !run("ip", &["-4", "rule", "show"], 3)?
        .lines()
        .any(|line| line.trim_start().starts_with("10060:") && line.contains("lookup 2060"))
    {
        run(
            "ip",
            &["-4", "rule", "add", "priority", "10060", "lookup", "2060"],
            3,
        )?;
    }
    Ok(())
}

impl Baseline {
    fn capture() -> Result<Self, String> {
        fn read(path: String) -> Result<String, String> {
            std::fs::read_to_string(path)
                .map(|s| s.trim().to_owned())
                .map_err(|_| "Cannot capture hotspot runtime settings".into())
        }
        let b = Self {
            mac_2g: read("/sys/class/net/wlan0/address".into())?,
            mac_5g: read("/sys/class/net/wlan2/address".into())?,
            ipv6_2g: read("/proc/sys/net/ipv6/conf/wlan0/disable_ipv6".into())?,
            ipv6_5g: read("/proc/sys/net/ipv6/conf/wlan2/disable_ipv6".into())?,
        };
        if !valid_mac(&b.mac_2g)
            || !valid_mac(&b.mac_5g)
            || !["0", "1"].contains(&b.ipv6_2g.as_str())
            || !["0", "1"].contains(&b.ipv6_5g.as_str())
        {
            return Err("Invalid hotspot runtime settings".into());
        }
        Ok(b)
    }
}
fn failure(code: u16, error: &str) -> (u16, Value) {
    (code, json!({"ok":false,"error":error}))
}
fn path(path: &Path) -> Result<&str, String> {
    path.to_str()
        .ok_or_else(|| "Invalid Wi-Fi runtime path".into())
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}
fn valid_mac(mac: &str) -> bool {
    let parts: Vec<_> = mac.split(':').collect();
    if parts.len() != 6
        || parts
            .iter()
            .any(|p| p.len() != 2 || !p.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return false;
    }
    let b: Vec<_> = parts
        .iter()
        .map(|p| u8::from_str_radix(p, 16).unwrap())
        .collect();
    b[0] & 1 == 0 && b.iter().any(|b| *b != 0)
}

/// Do not include command arguments or stderr: supplicant diagnostics can contain keys.
fn run(program: &str, args: &[&str], seconds: u64) -> Result<String, String> {
    let mut command = Command::new(program);
    // The agent starts with umask 077. Firmware-generated AP profiles must retain
    // the firmware's normal permissions so its jailed wifi user can read them.
    if program == "/sbin/wifi" {
        unsafe {
            command.pre_exec(|| {
                libc::umask(0o022);
                Ok(())
            });
        }
    }
    let mut child = command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .map_err(|_| format!("Cannot start Wi-Fi command {program}"))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or("Cannot capture Wi-Fi command output")?;
    // Nonblocking reads keep inherited daemon stdout from extending the deadline.
    let flags = unsafe { libc::fcntl(stdout.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(stdout.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err("Cannot capture Wi-Fi command output".into());
    }
    let mut output = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut exited = None;
    let status = loop {
        let mut buffer = [0; 8192];
        let mut read_error = false;
        loop {
            match stdout.read(&mut buffer) {
                Ok(0) => break,
                Ok(size) => {
                    output.extend_from_slice(&buffer[..size]);
                    if output.len() > 524288 {
                        read_error = true;
                        break;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    read_error = true;
                    break;
                }
            }
        }
        if read_error {
            break Err("Cannot read bounded Wi-Fi command output");
        }
        if let Some(status) = exited {
            break Ok(status);
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                exited = Some(status);
                continue;
            }
            Ok(None) => {}
            Err(_) => break Err("Cannot wait for Wi-Fi command"),
        }
        if Instant::now() >= deadline {
            break Err("Wi-Fi command timed out");
        }
        std::thread::sleep(Duration::from_millis(30));
    };
    if status.is_err() {
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
        let _ = child.wait();
    }
    if output.len() > 524288 {
        return Err("Wi-Fi command output is too large".into());
    }
    if !status.map_err(str::to_owned)?.success() {
        if program == "ip" {
            return Err(format!(
                "Wi-Fi network operation failed: ip {}",
                args.join(" ")
            ));
        }
        return Err(format!("Wi-Fi command {program} failed"));
    }
    String::from_utf8(output).map_err(|_| "Wi-Fi command returned invalid text".into())
}
fn json_command(program: &str, args: &[&str]) -> Result<Value, String> {
    serde_json::from_str(&run(program, args, 5)?).map_err(|_| "Invalid Wi-Fi network status".into())
}
/// IPv4 DNS servers the upstream network handed out with its DHCP lease.
fn uplink_dns_servers(status: &Value) -> Vec<Ipv4Addr> {
    status["dns-server"]
        .as_array()
        .map(|servers| servers.iter().filter_map(|v| v.as_str()?.parse().ok()).collect())
        .unwrap_or_default()
}

/// Resolves the NTP server through the uplink's own DNS first: the system resolver may still
/// forward to the cellular servers, which can stall right after the switch to Wi-Fi.
fn resolve_time_server(
    server: &str,
    status: &Value,
    mut lookup: impl FnMut(&str, Option<Ipv4Addr>) -> Result<String, String>,
) -> Result<Vec<Ipv4Addr>, String> {
    if let Ok(address) = server.parse::<Ipv4Addr>() {
        return Ok(vec![address]);
    }
    let mut failure = String::new();
    let resolvers = uplink_dns_servers(status).into_iter().take(2).map(Some).chain([None]);
    for dns in resolvers {
        match lookup(server, dns).and_then(|output| {
            crate::wifi_time::addresses(&output).map_err(String::from)
        }) {
            Ok(addresses) => return Ok(addresses),
            Err(error) => failure = error,
        }
    }
    Err(if failure.contains("timed out") {
        "The time server name could not be resolved: DNS lookup timed out".into()
    } else {
        format!("The time server name could not be resolved: {failure}")
    })
}

fn network_status() -> Result<Value, String> {
    json_command(
        "ubus",
        &[
            "-t",
            "3",
            "call",
            &format!("network.interface.{NETWORK}"),
            "status",
        ],
    )
}
fn validate_subnet(status: &Value) -> Result<(), String> {
    let lan = json_command(
        "ubus",
        &["-t", "3", "call", "network.interface.lan", "status"],
    )?;
    let parse = |value: &Value| -> Result<(Ipv4Addr, u32), String> {
        let address = value["address"]
            .as_str()
            .ok_or("Missing DHCP address")?
            .parse()
            .map_err(|_| "Invalid DHCP address")?;
        let mask = value["mask"]
            .as_u64()
            .filter(|m| *m <= 32)
            .ok_or("Invalid DHCP subnet")? as u32;
        Ok((address, mask))
    };
    let upstream = parse(&status["ipv4-address"][0])?;
    for address in lan["ipv4-address"].as_array().ok_or("Missing LAN subnet")? {
        let local = parse(address)?;
        if overlaps(upstream, local) {
            return Err(
                "Upstream Wi-Fi overlaps the router LAN; change the LAN subnet before connecting"
                    .into(),
            );
        }
    }
    Ok(())
}
fn overlaps(a: (Ipv4Addr, u32), b: (Ipv4Addr, u32)) -> bool {
    let prefix = a.1.min(b.1);
    let mask = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    u32::from(a.0) & mask == u32::from(b.0) & mask
}

fn firewall(config: Option<&Config>) -> Result<(), String> {
    for (table, base, chain) in [
        ("filter", "FORWARD", "OU60_WIFI_FWD"),
        ("filter", "INPUT", "OU60_WIFI_IN"),
        ("nat", "POSTROUTING", "OU60_WIFI_NAT"),
        ("mangle", "POSTROUTING", "OU60_WIFI_TTL"),
    ] {
        let rules = run("iptables", &["-w", "2", "-t", table, "-S"], 3)?;
        let exists = rules.lines().any(|line| line == format!("-N {chain}"));
        if !exists {
            if config.is_none() {
                continue;
            }
            run("iptables", &["-w", "2", "-t", table, "-N", chain], 3)?;
        }
        run("iptables", &["-w", "2", "-t", table, "-F", chain], 3)?;
        let hooked = rules
            .lines()
            .any(|line| line == format!("-A {base} -j {chain}"));
        if config.is_none() {
            if hooked {
                run(
                    "iptables",
                    &["-w", "2", "-t", table, "-D", base, "-j", chain],
                    3,
                )?;
            }
            run("iptables", &["-w", "2", "-t", table, "-X", chain], 3)?;
            continue;
        }
        if !hooked {
            run(
                "iptables",
                &["-w", "2", "-t", table, "-I", base, "1", "-j", chain],
                3,
            )?;
        }
    }
    if let Some(c) = config {
        let iface = c.band.interface();
        for rule in [
            vec!["-i", "br-lan", "-o", iface, "-j", "ACCEPT"],
            vec![
                "-i",
                iface,
                "-o",
                "br-lan",
                "-m",
                "conntrack",
                "--ctstate",
                "RELATED,ESTABLISHED",
                "-j",
                "ACCEPT",
            ],
        ] {
            let mut args = vec!["-w", "2", "-A", "OU60_WIFI_FWD"];
            args.extend(rule);
            run("iptables", &args, 3)?;
        }
        run(
            "iptables",
            &[
                "-w",
                "2",
                "-A",
                "OU60_WIFI_IN",
                "-i",
                iface,
                "-m",
                "conntrack",
                "--ctstate",
                "RELATED,ESTABLISHED",
                "-j",
                "ACCEPT",
            ],
            3,
        )?;
        run(
            "iptables",
            &[
                "-w",
                "2",
                "-A",
                "OU60_WIFI_IN",
                "-i",
                iface,
                "-p",
                "udp",
                "--sport",
                "67",
                "--dport",
                "68",
                "-j",
                "ACCEPT",
            ],
            3,
        )?;
        run(
            "iptables",
            &["-w", "2", "-A", "OU60_WIFI_IN", "-i", iface, "-j", "DROP"],
            3,
        )?;
        run(
            "iptables",
            &[
                "-w",
                "2",
                "-t",
                "nat",
                "-A",
                "OU60_WIFI_NAT",
                "-o",
                iface,
                "-j",
                "MASQUERADE",
            ],
            3,
        )?;
        if let Some(ttl) = c.ttl {
            run(
                "iptables",
                &[
                    "-w",
                    "2",
                    "-t",
                    "mangle",
                    "-A",
                    "OU60_WIFI_TTL",
                    "-o",
                    iface,
                    "-j",
                    "TTL",
                    "--ttl-set",
                    &ttl.to_string(),
                ],
                3,
            )?;
        }
        let forward = std::fs::read_to_string("/proc/sys/net/ipv4/ip_forward")
            .map_err(|_| "Cannot read IPv4 forwarding state")?;
        if forward.trim() != "1" {
            return Err("IPv4 forwarding is disabled on the router".into());
        }
    }
    native_redirect_bypass(config.is_some())?;
    Ok(())
}

const REDIRECT_BYPASS: &str =
    "-A redirect_chain -i br-lan -m comment --comment openu60-wifi-uplink -j RETURN";

fn native_redirect_bypass(enabled: bool) -> Result<(), String> {
    let rules = run("iptables", &["-w", "2", "-t", "nat", "-S"], 3)?;
    // With no vendor redirect chain there is no no-SIM captive redirect to bypass.
    if !rules.lines().any(|line| line == "-N redirect_chain") {
        return Ok(());
    }
    let present = rules.lines().any(|line| line == REDIRECT_BYPASS);
    if present != enabled {
        let mut args = vec![
            "-w",
            "2",
            "-t",
            "nat",
            if enabled { "-I" } else { "-D" },
            "redirect_chain",
        ];
        if enabled {
            args.push("1");
        }
        args.extend([
            "-i",
            "br-lan",
            "-m",
            "comment",
            "--comment",
            "openu60-wifi-uplink",
            "-j",
            "RETURN",
        ]);
        run("iptables", &args, 3)?;
    }
    Ok(())
}

fn firewall_present(config: &Config) -> Result<bool, String> {
    let iface = config.band.interface();
    let filter = run("iptables", &["-w", "2", "-t", "filter", "-S"], 3)?;
    let nat = run("iptables", &["-w", "2", "-t", "nat", "-S"], 3)?;
    let present = filter.contains("-A INPUT -j OU60_WIFI_IN")
        && filter.contains("-A FORWARD -j OU60_WIFI_FWD")
        && filter.contains(&format!("-A OU60_WIFI_IN -i {iface} -j DROP"))
        && nat.contains("-A POSTROUTING -j OU60_WIFI_NAT")
        && (!nat.lines().any(|line| line == "-N redirect_chain")
            || nat.lines().any(|line| line == REDIRECT_BYPASS))
        && nat.contains(&format!("-A OU60_WIFI_NAT -o {iface} -j MASQUERADE"));
    if let Some(ttl) = config.ttl {
        let mangle = run("iptables", &["-w", "2", "-t", "mangle", "-S"], 3)?;
        return Ok(present
            && mangle.contains("-A POSTROUTING -j OU60_WIFI_TTL")
            && mangle.contains(&format!(
                "-A OU60_WIFI_TTL -o {iface} -j TTL --ttl-set {ttl}"
            )));
    }
    Ok(present)
}

fn parse_scan(text: &str, band: Band) -> Vec<Network> {
    fn finish(network: Option<Network>, band: Band, out: &mut Vec<Network>) {
        if let Some(n) = network {
            if !n.ssid.is_empty() && band.contains(n.frequency) {
                out.push(n);
            }
        }
    }
    let mut result = vec![];
    let mut current: Option<Network> = None;
    let mut privacy = false;
    let mut rsn = false;
    for line in text.lines() {
        let line = line.trim();
        if let Some(bss) = line.strip_prefix("BSS ") {
            finish(current.take(), band, &mut result);
            privacy = false;
            rsn = false;
            let bssid = bss.split(['(', ' ']).next().unwrap_or("");
            if valid_mac(bssid) {
                current = Some(Network {
                    ssid: String::new(),
                    bssid: bssid.into(),
                    frequency: 0,
                    signal: -100,
                    security: "open".into(),
                    supported: true,
                });
            }
        } else if let Some(n) = current.as_mut() {
            if let Some(ssid) = line.strip_prefix("SSID: ") {
                n.ssid = decode_ssid(ssid);
            } else if let Some(frequency) = line.strip_prefix("freq: ") {
                n.frequency = frequency.parse().unwrap_or(0);
            } else if let Some(signal) = line.strip_prefix("signal: ") {
                n.signal = signal
                    .split_whitespace()
                    .next()
                    .and_then(|v| v.parse::<f32>().ok())
                    .map(|v| v as i32)
                    .unwrap_or(-100);
            } else if line.starts_with("capability:") && line.contains("Privacy") {
                privacy = true;
                n.security = "unsupported".into();
                n.supported = false;
            } else if line.contains("Authentication suites:") {
                if !rsn {
                    n.security = "unsupported".into();
                    n.supported = false;
                } else if line.contains("SAE") && line.contains("PSK") {
                    n.security = "mixed".into();
                    n.supported = true;
                } else if line.contains("SAE") {
                    n.security = "wpa3".into();
                    n.supported = true;
                } else if line.contains("PSK") {
                    n.security = "wpa2".into();
                    n.supported = true;
                } else {
                    n.security = "unsupported".into();
                    n.supported = false;
                }
            } else if line.starts_with("RSN:") || line.starts_with("WPA:") {
                rsn = line.starts_with("RSN:");
                if !privacy {
                    n.security = "unsupported".into();
                    n.supported = false;
                }
            }
        }
    }
    finish(current, band, &mut result);
    result.sort_by(|a, b| b.signal.cmp(&a.signal));
    result.truncate(128);
    result
}
fn decode_ssid(value: &str) -> String {
    let source = value.as_bytes();
    let mut bytes = vec![];
    let mut i = 0;
    while i < source.len() {
        if source[i] == b'\\' && source.get(i + 1) == Some(&b'x') && i + 3 < source.len() {
            if let Ok(hex) = std::str::from_utf8(&source[i + 2..i + 4]) {
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    bytes.push(byte);
                    i += 4;
                    continue;
                }
            }
        }
        bytes.push(source[i]);
        i += 1;
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn portal_result(
    status: u16,
    location: Option<&str>,
    body: &str,
) -> Result<(&'static str, Option<String>), String> {
    if status == 200 && body.contains("<BODY>Success</BODY>") {
        return Ok(("online", None));
    }
    if let Some(location) = location {
        let base = reqwest::Url::parse(PROBE).map_err(|_| "Invalid connectivity probe")?;
        let url = base
            .join(location)
            .map_err(|_| "Invalid captive portal URL")?;
        if !["http", "https"].contains(&url.scheme())
            || !url.username().is_empty()
            || url.password().is_some()
            || url.host_str().is_none()
            || url.as_str().len() > 4096
        {
            return Err("Unsafe captive portal URL".into());
        }
        return Ok(("captive", Some(url.to_string())));
    }
    Ok((
        if (200..300).contains(&status) { "captive" } else { "limited" },
        Some(PROBE.into()),
    ))
}
/// A working uplink is rechecked rarely; one that is offline or behind a portal is rechecked
/// often so a completed login shows up quickly.
fn probe_interval(connectivity: &str) -> Duration {
    Duration::from_secs(if connectivity == "online" { 600 } else { 30 })
}
fn probe_portal(iface: &str) -> Result<(&'static str, Option<String>), String> {
    let builder = reqwest::blocking::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(5));
    #[cfg(target_os = "linux")]
    let builder = builder.interface(iface);
    #[cfg(not(target_os = "linux"))]
    let _ = iface;
    let client = builder
        .build()
        .map_err(|_| "Cannot create connectivity probe")?;
    let response = client
        .get(PROBE)
        .send()
        .map_err(|_| "Connectivity probe failed")?;
    let status = response.status().as_u16();
    let location = response
        .headers()
        .get(reqwest::header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let mut body = String::new();
    response
        .take(4096)
        .read_to_string(&mut body)
        .map_err(|_| "Connectivity probe failed")?;
    portal_result(status, location.as_deref(), &body)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn time_server_lookup_prefers_the_uplink_dns() {
        let status = json!({"dns-server": ["192.168.1.1", "not-an-ip", "8.8.8.8", "::1"]});
        assert_eq!(
            uplink_dns_servers(&status),
            vec![Ipv4Addr::new(192, 168, 1, 1), Ipv4Addr::new(8, 8, 8, 8)]
        );
        assert!(uplink_dns_servers(&json!({})).is_empty());
        let mut asked = Vec::new();
        let found = resolve_time_server("pool.ntp.org", &status, |server, dns| {
            asked.push((server.to_string(), dns));
            if dns == Some(Ipv4Addr::new(192, 168, 1, 1)) {
                Err("Wi-Fi command timed out".into())
            } else {
                Ok("Server: 8.8.8.8\nName: pool.ntp.org\nAddress: 203.0.113.7\n".into())
            }
        });
        assert_eq!(found, Ok(vec![Ipv4Addr::new(203, 0, 113, 7)]));
        assert_eq!(asked.len(), 2);
        assert_eq!(asked[1].1, Some(Ipv4Addr::new(8, 8, 8, 8)));
        let literal = resolve_time_server("203.0.113.9", &status, |_, _| unreachable!());
        assert_eq!(literal, Ok(vec![Ipv4Addr::new(203, 0, 113, 9)]));
        let failed = resolve_time_server("pool.ntp.org", &json!({}), |_, dns| {
            assert_eq!(dns, None);
            Err("Wi-Fi command timed out".into())
        });
        assert_eq!(failed, Err("The time server name could not be resolved: DNS lookup timed out".into()));
    }


    #[test]
    fn control_socket_recovery_distinguishes_live_and_stale_daemons() {
        let root =
            std::env::temp_dir().join(format!("ou60-{}", &uuid::Uuid::new_v4().to_string()[..8]));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("wlan2");
        assert!(!supplicant_control_active(&path).unwrap());
        let daemon = UnixDatagram::bind(&path).unwrap();
        assert!(supplicant_control_active(&path).unwrap());
        drop(daemon);
        assert!(!supplicant_control_active(&path).unwrap());
        let restarted = UnixDatagram::bind(&path).unwrap();
        assert!(supplicant_control_active(&path).unwrap());
        drop(restarted);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_control_path_is_reported_and_preserved() {
        let root =
            std::env::temp_dir().join(format!("ou60-{}", &uuid::Uuid::new_v4().to_string()[..8]));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("wlan2");
        std::fs::write(&path, b"synthetic-state").unwrap();
        assert!(supplicant_control_active(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"synthetic-state");
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn random_identity_is_stable_for_the_saved_network() {
        let first: Change =
            serde_json::from_value(json!({"mode":"repeater","mac_mode":"random"})).unwrap();
        let first = first.merge(&config()).unwrap();
        assert!(valid_mac(&first.random_mac));
        let again: Change =
            serde_json::from_value(json!({"mode":"hotspot","mac_mode":"random"})).unwrap();
        assert_eq!(again.merge(&first).unwrap().random_mac, first.random_mac);
        let other:Change=serde_json::from_value(json!({"mode":"repeater","ssid":"Another","mac_mode":"random","password":"synthetic-password"})).unwrap();
        assert_ne!(other.merge(&first).unwrap().random_mac, first.random_mac);
    }
    #[test]
    fn policy_copies_connected_routes_without_reviving_a_down_usb_link() {
        assert!(!policy_has_routes("192.168.0.0/24 dev br-lan\n"));
        assert!(policy_has_routes(
            "unreachable default table 2060 metric 32767\n"
        ));
        assert!(!policy_has_routes("default table 20601 via 192.168.1.1\n"));
        let routes=connected_routes("192.168.0.0/24 dev br-lan proto static scope link metric 128\n192.168.1.0/24 dev wlan2 proto kernel scope link\n169.254.20.0/24 dev rndis0 scope link linkdown\n").unwrap();
        assert_eq!(
            routes,
            vec![
                ("192.168.0.0/24".into(), "br-lan".into()),
                ("192.168.1.0/24".into(), "wlan2".into())
            ]
        );
        for bad in [
            "192.168.0.0/33 dev br-lan",
            "192.168.0.0/24 dev bad;command",
            "unexpected route",
        ] {
            assert!(connected_routes(bad).is_err());
        }
    }
    #[test]
    fn commands_keep_output_and_enforce_the_deadline() {
        assert_eq!(
            run("/bin/sh", &["-c", "printf synthetic"], 1).unwrap(),
            "synthetic"
        );
        let started = Instant::now();
        assert!(run("/bin/sh", &["-c", "sleep 5"], 0)
            .unwrap_err()
            .contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(2));
    }
    fn config() -> Config {
        Config {
            mode: Mode::Repeater,
            ssid: "A network".into(),
            password: "synthetic-password".into(),
            ..Config::default()
        }
    }
    #[test]
    fn validates_security_and_mac_boundaries() {
        for band in [Band::Two, Band::Five] {
            let mut c = config();
            c.band = band;
            assert!(c.validate().is_ok());
        }
        for ssid in ["", "a\nnetwork", &"x".repeat(33)] {
            let mut c = config();
            c.ssid = ssid.into();
            assert!(c.validate().is_err());
        }
        for password in ["short", &"x".repeat(64), "contains\nnewline"] {
            let mut c = config();
            c.password = password.into();
            assert!(c.validate().is_err());
        }
        let mut c = config();
        c.password = "a".repeat(64);
        assert!(c.validate().is_ok());
        c.security = Security::Wpa3;
        assert!(c.validate().is_err());
        for mac in [
            "ff:ff:ff:ff:ff:ff",
            "01:22:33:44:55:66",
            "00:00:00:00:00:00",
            "02:33:44:55:66",
            "02:33:44:55:66:zz",
        ] {
            assert!(!valid_mac(mac));
        }
        assert!(valid_mac("02:33:44:55:66:77"));
    }
    #[test]
    fn profile_uses_hex_ssid_and_preserves_quoted_password() {
        let mut c = config();
        c.ssid = "中文 \"\\".into();
        c.password = "a\"b\\c123".into();
        let s = c.supplicant(Path::new("/test/control"));
        assert!(s.contains(&format!("ssid={}\n", hex(c.ssid.as_bytes()))));
        assert!(s.contains("psk=\"a\\\"b\\\\c123\""));
        assert!(s.contains("freq_list=2412 2417"));
        assert!(!s.contains("5180"));
        c.security = Security::Wpa3;
        assert!(c.supplicant(Path::new("/x")).contains("ieee80211w=2"));
        c.security = Security::Open;
        assert!(c.supplicant(Path::new("/x")).contains("key_mgmt=NONE"));
        assert!(!c.redacted().to_string().contains(&c.password));
    }
    #[test]
    fn new_network_never_reuses_another_network_password() {
        let prior = config();
        let change: Change =
            serde_json::from_value(json!({"mode":"repeater","ssid":"Another network"})).unwrap();
        assert!(change.merge(&prior).is_err());
        let change: Change =
            serde_json::from_value(json!({"mode":"repeater","band":"5g"})).unwrap();
        assert_eq!(change.merge(&prior).unwrap().password, prior.password);
        let change: Change =
            serde_json::from_value(json!({"mode":"repeater","security":"open"})).unwrap();
        assert_eq!(change.merge(&prior).unwrap().password, "");
    }
    #[test]
    fn scan_preserves_unicode_and_spaces_and_rejects_enterprise() {
        let text="BSS 02:11:22:33:44:55(on wlan2)\n freq: 5180\n signal: -62.00 dBm\n capability: ESS Privacy\n SSID: A network with spaces\n RSN:\n * Authentication suites: PSK SAE\nBSS 02:11:22:33:44:66(on wlan2)\n freq: 2412\n signal: -40.00 dBm\n SSID: \\xe4\\xb8\\xad\\xe6\\x96\\x87\nBSS 02:11:22:33:44:77(on wlan2)\n freq: 5200\n signal: -50.00 dBm\n capability: ESS Privacy\n SSID: Enterprise\n RSN:\n * Authentication suites: IEEE 802.1X\n";
        let five = parse_scan(text, Band::Five);
        assert_eq!(five.len(), 2);
        assert_eq!(five[0].ssid, "Enterprise");
        assert!(!five[0].supported);
        assert_eq!(five[1].ssid, "A network with spaces");
        assert_eq!(five[1].security, "mixed");
        assert_eq!(parse_scan(text, Band::Two)[0].ssid, "中文");
    }
    #[test]
    fn portal_handles_redirects_and_full_login_pages() {
        let success = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>";
        assert_eq!(portal_result(200, None, success).unwrap(), ("online", None));
        assert_eq!(
            portal_result(302, Some("https://login.example/auth"), "").unwrap(),
            ("captive", Some("https://login.example/auth".into()))
        );
        assert_eq!(
            portal_result(302, Some("/login?next=1"), "").unwrap(),
            ("captive", Some("https://www.apple.com/login?next=1".into()))
        );
        // A login page served in place of the success page is a portal, not the internet.
        assert_eq!(portal_result(200, None, "<html>Please sign in</html>").unwrap().0, "captive");
        assert_eq!(portal_result(204, None, "").unwrap().0, "captive");
        assert_eq!(portal_result(503, None, success).unwrap().0, "limited");
        for location in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "https://user:pass@login.example/",
        ] {
            assert!(portal_result(302, Some(location), "").is_err());
        }
    }
    #[test]
    fn a_working_uplink_is_probed_rarely() {
        assert_eq!(probe_interval("online"), Duration::from_secs(600));
        for state in ["captive", "limited", "offline", ""] {
            assert_eq!(probe_interval(state), Duration::from_secs(30));
        }
    }
    #[test]
    fn detects_overlapping_dhcp_subnets() {
        let ip = |s: &str| s.parse().unwrap();
        assert!(overlaps((ip("192.168.0.3"), 24), (ip("192.168.0.1"), 24)));
        assert!(overlaps((ip("10.1.5.3"), 24), (ip("10.0.0.1"), 8)));
        assert!(!overlaps((ip("192.168.1.3"), 24), (ip("192.168.0.1"), 24)));
    }
    #[test]
    fn admission_is_durable_and_second_writer_is_rejected() {
        let root = std::env::temp_dir().join(format!("openu60-wifi-test-{}", uuid::Uuid::new_v4()));
        let service = WifiUplink::at(&root);
        let body = serde_json::to_vec(
            &json!({"mode":"repeater","ssid":"Synthetic","password":"synthetic-password"}),
        )
        .unwrap();
        assert_eq!(service.apply(&body).0, 202);
        assert_eq!(service.apply(&body).0, 409);
        let saved: Record =
            serde_json::from_slice(&private_read(&root.join("profile.private.json")).unwrap())
                .unwrap();
        assert_eq!(saved.phase, "pending");
        assert_eq!(saved.config.ssid, "Synthetic");
        assert!(!service
            .status()
            .1
            .to_string()
            .contains("synthetic-password"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn local_screen_uses_the_same_admission_and_redacted_status() {
        let root =
            std::env::temp_dir().join(format!("openu60-screen-test-{}", uuid::Uuid::new_v4()));
        let service = WifiUplink::at(&root);
        let request = br#"{"action":"apply","body":{"mode":"repeater","ssid":"Synthetic","password":"synthetic-password","security":"auto"}}"#;
        assert_eq!(service.ui_request(request).0, 202);
        assert_eq!(service.apply(br#"{"mode":"hotspot"}"#).0, 409);
        let (code, status) = service.ui_request(br#"{"action":"status"}"#);
        assert_eq!(code, 200);
        assert_eq!(status["data"]["busy"], true);
        assert_eq!(status["data"]["config"]["has_password"], true);
        assert!(!status.to_string().contains("synthetic-password"));
        assert_eq!(service.ui_request(&vec![b' '; 8193]).0, 413);
        std::fs::remove_dir_all(root).unwrap();
    }
}
