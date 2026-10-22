use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::cache;
use crate::handlers::AppState;
use crate::remote_calling::storage::{private_read, private_write};
use crate::ubus;

const PHONE_NUMBERS_PATH: &str = "/data/openu60-sim/phone-numbers.json";

use crate::cellular_line::CellularLine;

fn line_from(data: &Value) -> Result<CellularLine, String> {
    let iccid = active_iccid(data).ok_or("sim_line_not_ready")?;
    let number = data["msisdn"].as_str().ok_or("invalid_sim_phone_number")?;
    let normalized = normalize_phone_number(number).ok_or("invalid_sim_phone_number")?;
    Ok(CellularLine {
        iccid: iccid.into(),
        number: (!normalized.is_empty()).then_some(normalized),
        source: data["msisdn_source"].as_str().ok_or("invalid_sim_phone_number_source")?.into(),
    })
}

/// Capture from fresh firmware identity; an IP address or the last selected profile is not a line.
pub(crate) fn capture_line(state: &AppState) -> Result<CellularLine, String> {
    let mut data = ubus::call("zwrt_zte_mdm.api", "get_sim_info", Some("{}")).map_err(|_| "sim_line_unavailable")?;
    state.sim_phone_numbers.apply(&mut data)?;
    let line = line_from(&data)?;
    let verified = ubus::call("zwrt_zte_mdm.api", "get_sim_info", Some("{}")).map_err(|_| "sim_line_unavailable")?;
    if active_iccid(&verified) != Some(line.iccid.as_str()) { return Err("sim_line_changed".into()); }
    Ok(line)
}

#[derive(Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SavedPhoneNumbers {
    numbers: BTreeMap<String, String>,
}

pub struct SimPhoneNumbers {
    file: PathBuf,
    lock: Mutex<()>,
}

impl SimPhoneNumbers {
    pub fn new() -> Self {
        Self::at(Path::new(PHONE_NUMBERS_PATH))
    }

    fn at(file: &Path) -> Self {
        Self {
            file: file.into(),
            lock: Mutex::new(()),
        }
    }

    fn load(&self) -> Result<SavedPhoneNumbers, String> {
        match std::fs::symlink_metadata(&self.file) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(SavedPhoneNumbers::default())
            }
            Err(_) => return Err("sim_phone_numbers_unavailable".into()),
            Ok(_) => {}
        }
        let saved: SavedPhoneNumbers = serde_json::from_slice(&private_read(&self.file)?)
            .map_err(|_| "invalid_saved_sim_phone_numbers")?;
        if saved.numbers.iter().any(|(iccid, number)| {
            !valid_iccid(iccid)
                || number.is_empty()
                || normalize_phone_number(number).as_deref() != Some(number.as_str())
        }) {
            return Err("invalid_saved_sim_phone_numbers".into());
        }
        Ok(saved)
    }

    fn get(&self, iccid: &str) -> Result<Option<String>, String> {
        let _guard = self.lock.lock().unwrap();
        Ok(self.load()?.numbers.get(iccid).cloned())
    }

    fn set(&self, iccid: &str, number: &str) -> Result<(), String> {
        let _guard = self.lock.lock().unwrap();
        if !valid_iccid(iccid) {
            return Err("invalid_sim_identity".into());
        }
        let number = normalize_phone_number(number).ok_or("invalid_sim_phone_number")?;
        let mut saved = self.load()?;
        if number.is_empty() {
            saved.numbers.remove(iccid);
        } else {
            saved.numbers.insert(iccid.into(), number);
        }
        let bytes = serde_json::to_vec(&saved).map_err(|_| "sim_phone_numbers_encode")?;
        if bytes.len() > 262144 {
            return Err("sim_phone_numbers_full".into());
        }
        private_write(&self.file, &bytes)
    }

    fn apply(&self, data: &mut Value) -> Result<(), String> {
        let Some(iccid) = active_iccid(data).map(str::to_owned) else {
            return set_number_fields(data, "", "unavailable");
        };
        if let Some(number) = self.get(&iccid)? {
            set_number_fields(data, &number, "manual")
        } else {
            restore_phone_number(data, read_phone_number)?;
            let source = if data["msisdn"].as_str() == Some("") {
                "unavailable"
            } else {
                "sim"
            };
            data["msisdn_source"] = json!(source);
            Ok(())
        }
    }
}

fn valid_iccid(iccid: &str) -> bool {
    (18..=22).contains(&iccid.len())
        && iccid
            .bytes()
            .all(|b| b.is_ascii_digit() || b == b'F' || b == b'f')
}

fn active_iccid(data: &Value) -> Option<&str> {
    if crate::esim::sim_states_ready(data) != Some(true) {
        return None;
    }
    data["sim_iccid"]
        .as_str()
        .map(str::trim)
        .filter(|s| valid_iccid(s))
}

fn normalize_phone_number(number: &str) -> Option<String> {
    let mut normalized = String::new();
    for c in number.chars() {
        match c {
            '0'..='9' => normalized.push(c),
            '+' if normalized.is_empty() => normalized.push(c),
            ' ' | '-' | '(' | ')' => {}
            _ => return None,
        }
    }
    let digits = normalized.strip_prefix('+').unwrap_or(&normalized);
    (normalized.is_empty() || (3..=15).contains(&digits.len())).then_some(normalized)
}

fn set_number_fields(data: &mut Value, number: &str, source: &str) -> Result<(), String> {
    let fields = data.as_object_mut().ok_or("invalid_sim_info")?;
    fields.insert("msisdn".into(), json!(number));
    fields.insert("msisdn_source".into(), json!(source));
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PhoneNumberUpdate {
    iccid: String,
    number: String,
}

fn check_phone_number_update(data: &Value, request: &PhoneNumberUpdate) -> Result<String, u16> {
    let number = normalize_phone_number(&request.number).ok_or(400u16)?;
    if !valid_iccid(&request.iccid) {
        return Err(400);
    }
    if active_iccid(data) != Some(request.iccid.as_str()) {
        return Err(409);
    }
    Ok(number)
}

pub fn sim_phone_number_set(state: &AppState, body: &[u8]) -> (u16, Value) {
    let request: PhoneNumberUpdate = match serde_json::from_slice(body) {
        Ok(request) => request,
        Err(_) => {
            return (
                400,
                json!({"ok": false, "error": "invalid_phone_number_request"}),
            )
        }
    };
    let mut data = match ubus::call("zwrt_zte_mdm.api", "get_sim_info", Some("{}")) {
        Ok(data) => data,
        Err(_) => return (503, json!({"ok": false, "error": "sim_info_unavailable"})),
    };
    let number = match check_phone_number_update(&data, &request) {
        Ok(number) => number,
        Err(409) => {
            return (
                409,
                json!({"ok": false, "error": "SIM changed or is not ready. Refresh and try again."}),
            )
        }
        Err(_) => {
            return (
                400,
                json!({"ok": false, "error": "Enter a phone number with 3 to 15 digits, optionally starting with +."}),
            )
        }
    };
    if let Err(error) = restore_imsi(&mut data, read_imsi) {
        return (503, json!({"ok": false, "error": error}));
    }
    // Prepare the response before committing so a later firmware read cannot
    // turn a successfully saved edit into a reported failure.
    let result = if number.is_empty() {
        restore_phone_number(&mut data, read_phone_number).map(|()| {
            data["msisdn_source"] = json!(if data["msisdn"].as_str() == Some("") {
                "unavailable"
            } else {
                "sim"
            });
        })
    } else {
        set_number_fields(&mut data, &number, "manual")
    };
    if let Err(error) = result.and_then(|()| state.sim_phone_numbers.set(&request.iccid, &number)) {
        return (503, json!({"ok": false, "error": error}));
    }
    if let Some(fields) = data.as_object_mut() {
        state.sim_identity.stamp(fields);
    }
    (200, json!({"ok": true, "data": data}))
}

pub fn sim_info(state: &AppState) -> (u16, Value) {
    match info(state) {
        Ok(mut data) => {
            if let Some(obj) = data.as_object_mut() {
                state.sim_identity.stamp(obj);
            }
            (200, json!({"ok": true, "data": data}))
        }
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

/// `get_sim_info`, through the shared cache.
pub(crate) fn info(state: &AppState) -> Result<Value, String> {
    let fetch = || ubus::call("zwrt_zte_mdm.api", "get_sim_info", Some("{}"));
    let mut data = state
        .cache
        .get_or_fetch(cache::SIM_INFO, cache::SIM_INFO_TTL, fetch)?;
    restore_imsi(&mut data, read_imsi)?;
    state.sim_phone_numbers.apply(&mut data)?;
    Ok(data)
}

fn read_imsi() -> Result<String, String> {
    ubus::uci_get("zwrt_zte_mdm.sim_info.sim_imsi").map_err(|_| "sim_imsi_unavailable".into())
}

fn restore_imsi(
    data: &mut Value,
    read: impl FnOnce() -> Result<String, String>,
) -> Result<(), String> {
    if !data.is_object() {
        return Err("invalid_sim_info".into());
    }
    if active_iccid(data).is_none() {
        data["sim_imsi"] = json!("");
        return Ok(());
    }
    // The firmware encrypts sim_imsi in get_sim_info; UCI retains the original digits.
    let imsi = read().map_err(|_| "sim_imsi_unavailable")?;
    let imsi = imsi.trim();
    if imsi.len() > 15 || !imsi.bytes().all(|b| b.is_ascii_digit()) {
        return Err("invalid_sim_imsi".into());
    }
    data["sim_imsi"] = json!(imsi);
    Ok(())
}

fn read_phone_number() -> Result<String, String> {
    // A missing option is a SIM without a stored number; a missing section is
    // an unavailable firmware source and must not be reported as an empty number.
    ubus::uci_get("zwrt_zte_mdm.sim_info")?;
    let output = std::process::Command::new("uci")
        .args(["get", "zwrt_zte_mdm.sim_info.msisdn"])
        .output()
        .map_err(|_| "sim_phone_number_unavailable")?;
    phone_number_field(output)
}

fn phone_number_field(output: std::process::Output) -> Result<String, String> {
    if output.status.success() {
        return String::from_utf8(output.stdout).map_err(|_| "invalid_sim_phone_number".into());
    }
    if output.status.code() == Some(1)
        && output.stdout.is_empty()
        && output.stderr.as_slice().trim_ascii() == b"uci: Entry not found"
    {
        return Ok(String::new());
    }
    Err("sim_phone_number_unavailable".into())
}

fn restore_phone_number(
    data: &mut Value,
    read_number: impl FnOnce() -> Result<String, String>,
) -> Result<(), String> {
    let fields = data.as_object_mut().ok_or("invalid_sim_info")?;
    // get_sim_info encrypts even an empty MSISDN. Its firmware handler reads
    // this same UCI field before encryption; a blank value means the SIM has no number.
    let number = read_number().map_err(|_| "sim_phone_number_unavailable")?;
    let number = number.trim();
    let digits = number.strip_prefix('+').unwrap_or(number);
    if !number.is_empty()
        && (!(3..=15).contains(&digits.len()) || !digits.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err("invalid_sim_phone_number".into());
    }
    fields.insert("msisdn".into(), json!(number));
    Ok(())
}

/// PIN/PUK/lock operations change `get_sim_info` (state, remaining tries)
/// and the modem re-registers afterwards; drop the entry and keep reads
/// near-fresh for the settle window. Applied on failure too: a wrong PIN
/// still decrements the counter.
fn settle_sim_info(state: &AppState) {
    state
        .cache
        .invalidate_with_settle(cache::SIM_INFO, cache::SETTLE_WINDOW);
}

pub fn sim_imei(_state: &AppState) -> (u16, Value) {
    match ubus::call("zwrt_zte_mdm.api", "get_imei", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn sim_pin_verify(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    let result = ubus::call(
        "zwrt_zte_mdm.api",
        "sim_verify_pin_puk",
        Some(&parsed.to_string()),
    );
    settle_sim_info(state);
    match result {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn sim_pin_change(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    let result = ubus::call(
        "zwrt_zte_mdm.api",
        "sim_change_pin",
        Some(&parsed.to_string()),
    );
    settle_sim_info(state);
    match result {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn sim_pin_mode(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    let result = ubus::call(
        "zwrt_zte_mdm.api",
        "sim_change_pin_mode",
        Some(&parsed.to_string()),
    );
    settle_sim_info(state);
    match result {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn sim_unlock(state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    let result = ubus::call(
        "zwrt_zte_mdm.api",
        "set_simlock_nck",
        Some(&parsed.to_string()),
    );
    settle_sim_info(state);
    match result {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn sim_lock_trials(_state: &AppState) -> (u16, Value) {
    match ubus::call(
        "zwrt_zte_mdm.api",
        "get_simlock_available_trials",
        Some("{}"),
    ) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIM_A: &str = "8901000000000000001F";
    const SIM_B: &str = "8901000000000000002F";

    fn sim(iccid: &str) -> Value {
        json!({"sim_states": "sim ready", "sim_iccid": iccid, "msisdn": "encoded-value"})
    }

    struct PhoneBookTest {
        directory: PathBuf,
        book: SimPhoneNumbers,
    }

    impl PhoneBookTest {
        fn new() -> Self {
            let directory =
                std::env::temp_dir().join(format!("u60-sim-phone-{}", uuid::Uuid::new_v4()));
            let book = SimPhoneNumbers::at(&directory.join("numbers.json"));
            Self { directory, book }
        }
    }

    impl Drop for PhoneBookTest {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    #[test]
    fn sim_info_restores_complete_plain_imsi_digits() {
        for imsi in ["001011234567890", "00101123456789", ""] {
            let mut data = sim(SIM_A);
            data["sim_imsi"] = json!("encoded-imsi==");
            restore_imsi(&mut data, || Ok(format!("{imsi}\n"))).unwrap();
            assert_eq!(data["sim_imsi"], imsi);
            assert_eq!(data["sim_iccid"], SIM_A);
        }
    }

    #[test]
    fn imsi_is_unavailable_without_a_ready_sim() {
        for status in ["sim undetected", "wait pin", "not ready"] {
            let mut data = sim(SIM_A);
            data["sim_states"] = json!(status);
            data["sim_imsi"] = json!("encoded-imsi==");
            restore_imsi(&mut data, || {
                unreachable!("Do not expose stale IMSI for an unready SIM")
            })
            .unwrap();
            assert_eq!(data["sim_imsi"], "");
        }
    }

    #[test]
    fn invalid_or_unreadable_imsi_fails_without_exposing_its_value() {
        for imsi in [
            "encoded-imsi==",
            "0010112345678901",
            "+001011234567890",
            "００１０１１２３４５６７８９０",
            "00101\n1234567890",
        ] {
            let mut data = sim(SIM_A);
            assert_eq!(
                restore_imsi(&mut data, || Ok(imsi.into())),
                Err("invalid_sim_imsi".into())
            );
        }
        assert_eq!(
            restore_imsi(&mut sim(SIM_A), || Err("private error text".into())),
            Err("sim_imsi_unavailable".into())
        );
        assert_eq!(
            restore_imsi(&mut Value::Null, || unreachable!()),
            Err("invalid_sim_info".into())
        );
    }

    #[test]
    fn manual_numbers_persist_per_sim_and_can_return_to_automatic() {
        let test = PhoneBookTest::new();
        test.book.set(SIM_A, "06 1234-5678").unwrap();
        test.book.set(SIM_B, "+31 (6) 2345-6789").unwrap();
        let reopened = SimPhoneNumbers::at(&test.book.file);
        assert_eq!(reopened.get(SIM_A).unwrap().as_deref(), Some("0612345678"));
        assert_eq!(
            reopened.get(SIM_B).unwrap().as_deref(),
            Some("+31623456789")
        );
        let mut data = sim(SIM_A);
        reopened.apply(&mut data).unwrap();
        assert_eq!(data["msisdn"], "0612345678");
        assert_eq!(data["msisdn_source"], "manual");
        reopened.set(SIM_A, "").unwrap();
        assert_eq!(reopened.get(SIM_A).unwrap(), None);
        assert_eq!(
            reopened.get(SIM_B).unwrap().as_deref(),
            Some("+31623456789")
        );
        let mut absent = sim(SIM_B);
        absent["sim_states"] = json!("sim undetected");
        reopened.apply(&mut absent).unwrap();
        assert_eq!(absent["msisdn"], "");
        assert_eq!(absent["msisdn_source"], "unavailable");
    }

    #[test]
    fn number_edits_reject_a_changed_or_unready_sim() {
        let request = PhoneNumberUpdate {
            iccid: SIM_A.into(),
            number: "06 1234 5678".into(),
        };
        assert_eq!(
            check_phone_number_update(&sim(SIM_A), &request).unwrap(),
            "0612345678"
        );
        assert_eq!(check_phone_number_update(&sim(SIM_B), &request), Err(409));
        let mut locked = sim(SIM_A);
        locked["sim_states"] = json!("wait pin");
        assert_eq!(check_phone_number_update(&locked, &request), Err(409));
        for number in ["+", "12", "1234567890123456", "１２３", "123\n456"] {
            let request = PhoneNumberUpdate {
                iccid: SIM_A.into(),
                number: number.into(),
            };
            assert_eq!(check_phone_number_update(&sim(SIM_A), &request), Err(400));
        }
    }

    #[test]
    fn concurrent_phone_edits_preserve_both_sims() {
        let test = PhoneBookTest::new();
        std::thread::scope(|scope| {
            scope.spawn(|| test.book.set(SIM_A, "0612345678").unwrap());
            scope.spawn(|| test.book.set(SIM_B, "0623456789").unwrap());
        });
        assert_eq!(test.book.get(SIM_A).unwrap().as_deref(), Some("0612345678"));
        assert_eq!(test.book.get(SIM_B).unwrap().as_deref(), Some("0623456789"));
    }

    #[test]
    fn invalid_or_unreadable_phone_books_are_not_overwritten() {
        let test = PhoneBookTest::new();
        test.book.set(SIM_A, "0612345678").unwrap();
        let previous = private_read(&test.book.file).unwrap();
        assert!(test.book.set(SIM_A, "invalid").is_err());
        assert_eq!(private_read(&test.book.file).unwrap(), previous);
        std::fs::write(&test.book.file, b"invalid JSON").unwrap();
        assert!(test.book.set(SIM_B, "0623456789").is_err());
        assert_eq!(std::fs::read(&test.book.file).unwrap(), b"invalid JSON");
    }

    #[test]
    fn phone_number_uses_the_same_plain_field_as_the_firmware() {
        for number in ["0612345678", "+31612345678", "123", "123456789012345"] {
            let mut data =
                json!({"msisdn": "encoded-value", "Operator": "Example", "pinnumber": 3});
            restore_phone_number(&mut data, || Ok(number.into())).unwrap();
            assert_eq!(data["msisdn"], number);
            assert_eq!(data["Operator"], "Example");
            assert_eq!(data["pinnumber"], 3);
        }
    }

    #[test]
    fn a_sim_without_a_stored_number_returns_an_empty_number() {
        let mut data = json!({"msisdn": "encoded-empty-value"});
        restore_phone_number(&mut data, || Ok(String::new())).unwrap();
        assert_eq!(data["msisdn"], "");
    }

    #[test]
    fn missing_phone_option_is_distinct_from_a_failed_firmware_read() {
        use std::os::unix::process::ExitStatusExt;
        let result = |code, stdout: &[u8], stderr: &[u8]| std::process::Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: stdout.into(),
            stderr: stderr.into(),
        };
        assert_eq!(
            phone_number_field(result(0, b"+31612345678\n", b"")).unwrap(),
            "+31612345678\n"
        );
        assert_eq!(
            phone_number_field(result(1, b"", b"uci: Entry not found\n")).unwrap(),
            ""
        );
        assert!(phone_number_field(result(1, b"", b"uci: Permission denied\n")).is_err());
        assert!(phone_number_field(result(2, b"", b"uci: Entry not found\n")).is_err());
        assert!(phone_number_field(result(0, b"\xff", b"")).is_err());
    }

    #[test]
    fn unreadable_or_invalid_numbers_fail_without_exposing_the_value() {
        for number in ["encoded-value==", "+", "12", "1234567890123456", "123\n456"] {
            let mut data = json!({"msisdn": "encoded-value"});
            assert_eq!(
                restore_phone_number(&mut data, || Ok(number.into())).unwrap_err(),
                "invalid_sim_phone_number"
            );
        }
        let mut data = json!({"msisdn": "encoded-value"});
        assert_eq!(
            restore_phone_number(&mut data, || Err("private error text".into())).unwrap_err(),
            "sim_phone_number_unavailable"
        );
        assert_eq!(
            restore_phone_number(&mut Value::Null, || unreachable!()).unwrap_err(),
            "invalid_sim_info"
        );
    }
}
