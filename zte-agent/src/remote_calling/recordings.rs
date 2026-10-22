use super::storage::{private_read, private_write};
use super::journal::CallPhone;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Mutex,
};
use std::time::{Duration, Instant};
use tiny_http::Method;
use uuid::Uuid;

const RATE: u32 = 8000;
const CHUNK: usize = 65536;
const RESERVE: u64 = 64 * 1024 * 1024;
const PAGE: usize = 100;

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CallRecord {
    pub id: Uuid,
    pub number: Option<String>,
    pub direction: String,
    pub state: String,
    pub started_at: u64,
    pub answered_at: Option<u64>,
    pub ended_at: Option<u64>,
    pub reason: Option<String>,
    pub recording_state: String,
    pub recording_error: Option<String>,
    pub bytes: u64,
    pub duration_ms: u64,
    #[serde(default)]
    pub has_transcript: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phone: Option<CallPhone>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<crate::cellular_line::CellularLine>,
}
#[derive(Clone)]
pub struct RecordingSink {
    sender: mpsc::SyncSender<(usize, Vec<u8>)>,
    overflow: Arc<AtomicBool>,
}
impl RecordingSink {
    pub fn push(&self, channel: usize, pcm: &[u8]) {
        if channel > 1 || pcm.is_empty() || pcm.len() % 2 != 0 || pcm.len() > 8192 {
            self.overflow.store(true, Ordering::Release);
            return;
        }
        if self.sender.try_send((channel, pcm.to_vec())).is_err() {
            self.overflow.store(true, Ordering::Release);
        }
    }
}
pub struct Recordings {
    root: PathBuf,
    records: Mutex<Option<BTreeMap<Uuid, CallRecord>>>,
    active: Mutex<HashMap<Uuid, RecordingSink>>,
    error: Mutex<Option<String>>,
}
impl Recordings {
    pub fn new() -> Arc<Self> {
        Self::at(Path::new("/data/openu60-recordings"))
    }
    fn at(root: &Path) -> Arc<Self> {
        Arc::new(Self {
            root: root.into(),
            records: Mutex::new(None),
            active: Mutex::new(HashMap::new()),
            error: Mutex::new(None),
        })
    }
    fn metadata(&self, id: Uuid) -> PathBuf {
        self.root.join(format!("{id}.json"))
    }
    fn audio(&self, id: Uuid) -> PathBuf {
        self.root.join(format!("{id}.wav"))
    }
    fn transcript_path(&self, id: Uuid) -> PathBuf {
        self.root.join(format!("{id}.transcript"))
    }
    pub fn note_error(&self, error: String) {
        eprintln!("[recordings] {error}");
        *self.error.lock().unwrap() = Some(error);
    }
    fn save(&self, record: &CallRecord) -> Result<(), String> {
        private_write(
            &self.metadata(record.id),
            &serde_json::to_vec(record).map_err(|_| "recording_metadata_encode")?,
        )
    }
    fn load(&self, slot: &mut Option<BTreeMap<Uuid, CallRecord>>) -> Result<(), String> {
        if slot.is_some() {
            return Ok(());
        }
        let entries = match fs::read_dir(&self.root) {
            Ok(entries) => Some(entries),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return Err("recording_directory_read".into()),
        };
        let mut records = BTreeMap::new();
        if let Some(entries) = entries {
            for entry in entries {
                let entry = entry.map_err(|_| "recording_directory_read")?;
                let path = entry.path();
                if path.extension().and_then(|s| s.to_str()) != Some("json") {
                    continue;
                }
                let id = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .and_then(|s| Uuid::parse_str(s).ok())
                    .ok_or("invalid_recording_name")?;
                let mut record: CallRecord = serde_json::from_slice(&private_read(&path)?)
                    .map_err(|_| "invalid_recording_metadata")?;
                if record.id != id {
                    return Err("recording_identity_mismatch".into());
                }
                // A new process never adopts a previous writer or silently erases its audio.
                if record.state != "ended" || record.recording_state == "recording" {
                    record.state = "ended".into();
                    record.reason = Some("agent_restarted".into());
                    if record.recording_state == "recording" {
                        let mut file = OpenOptions::new()
                            .read(true)
                            .write(true)
                            .custom_flags(libc::O_NOFOLLOW)
                            .open(self.audio(id))
                            .map_err(|_| "recording_recovery_open")?;
                        let length = file
                            .metadata()
                            .map_err(|_| "recording_recovery_stat")?
                            .len();
                        if length < 44 || (length - 44) % 4 != 0 {
                            return Err("invalid_recording_audio".into());
                        }
                        wav_header(&mut file, length - 44)?;
                        file.sync_all().map_err(|_| "recording_recovery_sync")?;
                        record.bytes = length;
                        record.duration_ms = (length - 44) * 1000 / (u64::from(RATE) * 4);
                        record.recording_state = "interrupted".into();
                    }
                    self.save(&record)?;
                }
                records.insert(id, record);
            }
        }
        *slot = Some(records);
        Ok(())
    }
    pub fn observe(
        &self,
        id: Uuid,
        number: Option<String>,
        incoming: bool,
        state: &str,
        now: u64,
        reason: Option<&str>,
        line: Option<crate::cellular_line::CellularLine>,
    ) -> Result<(), String> {
        let mut slot = self.records.lock().unwrap();
        self.load(&mut slot)?;
        let records = slot.as_mut().unwrap();
        let mut record = records.get(&id).cloned().unwrap_or(CallRecord {
            id,
            number,
            direction: if incoming { "incoming" } else { "outgoing" }.into(),
            state: state.into(),
            started_at: now,
            answered_at: None,
            ended_at: None,
            reason: None,
            recording_state: "none".into(),
            recording_error: None,
            bytes: 0,
            duration_ms: 0,
            has_transcript: false,
            phone: None,
            line,
        });
        record.state = state.into();
        record.reason = reason.map(String::from);
        if state == "active" && record.answered_at.is_none() {
            record.answered_at = Some(now);
        }
        if state == "ended" {
            record.ended_at = Some(now);
        }
        if records.get(&id) == Some(&record) {
            return Ok(());
        }
        self.save(&record)?;
        records.insert(id, record);
        *self.error.lock().unwrap() = None;
        Ok(())
    }
    pub fn assign_phone(&self, id: Uuid, phone: &CallPhone) -> Result<(), String> {
        phone.validate()?;
        let mut slot = self.records.lock().unwrap();
        self.load(&mut slot)?;
        let records = slot.as_mut().unwrap();
        let mut record = records.get(&id).cloned().ok_or("recording_call_missing")?;
        if let Some(current) = &record.phone {
            return if current == phone { Ok(()) } else { Err("recording_phone_conflict".into()) };
        }
        record.phone = Some(phone.clone());
        self.save(&record)?;
        records.insert(id, record);
        Ok(())
    }
    fn update_recording(&self, id: Uuid, state: &str, error: Option<String>) -> Result<(), String> {
        let mut slot = self.records.lock().unwrap();
        self.load(&mut slot)?;
        let records = slot.as_mut().unwrap();
        let mut record = records.get(&id).cloned().ok_or("recording_call_missing")?;
        record.recording_state = state.into();
        record.recording_error = error;
        match fs::metadata(self.audio(id)) {
            Ok(meta) => {
                record.bytes = meta.len();
                record.duration_ms = meta.len().saturating_sub(44) * 1000 / (u64::from(RATE) * 4);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("recording_audio_stat".into()),
        }
        self.save(&record)?;
        records.insert(id, record);
        Ok(())
    }
    pub fn start(self: &Arc<Self>, id: Uuid) -> Result<RecordingSink, String> {
        let mut active = self.active.lock().unwrap();
        if let Some(sink) = active.get(&id) {
            return Ok(sink.clone());
        }
        {
            let mut slot = self.records.lock().unwrap();
            self.load(&mut slot)?;
            let record = slot
                .as_ref()
                .unwrap()
                .get(&id)
                .ok_or("recording_call_missing")?;
            if record.recording_state != "none" {
                return Err("recording_already_finished".into());
            }
        }
        let opened = (|| {
            let mut file = OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(self.audio(id))
                .map_err(|_| "recording_audio_create")?;
            wav_header(&mut file, 0)?;
            ensure_space(&file, RESERVE)?;
            file.sync_all().map_err(|_| "recording_audio_sync")?;
            self.update_recording(id, "recording", None)?;
            Ok::<_, String>(file)
        })();
        let file = match opened {
            Ok(file) => file,
            Err(error) => {
                self.update_recording(id, "failed", Some(error.clone()))?;
                return Err(error);
            }
        };
        let (sender, receiver) = mpsc::sync_channel(64);
        let overflow = Arc::new(AtomicBool::new(false));
        let sink = RecordingSink {
            sender,
            overflow: overflow.clone(),
        };
        let store = self.clone();
        if let Err(error) = std::thread::Builder::new()
            .name("call-recorder".into())
            .spawn(move || {
                let result = write_audio(file, receiver, &overflow, RESERVE);
                let (state, error) = match result {
                    Ok(()) => ("complete", None),
                    Err(error) => ("failed", Some(error)),
                };
                if let Err(error) = store.update_recording(id, state, error) {
                    store.note_error(format!("recording_finalization: {error}"));
                }
            })
        {
            self.update_recording(
                id,
                "failed",
                Some(format!("recording_worker_start: {error}")),
            )?;
            return Err("recording_worker_start".into());
        }
        active.insert(id, sink.clone());
        Ok(sink)
    }
    pub fn stop(&self, id: Uuid) {
        self.active.lock().unwrap().remove(&id);
    }
    pub fn snapshot(&self, recordings_only: bool, offset: usize) -> Result<Value, String> {
        let mut slot = self.records.lock().unwrap();
        self.load(&mut slot)?;
        let mut records = slot.as_ref().unwrap().values().cloned().collect::<Vec<_>>();
        if recordings_only {
            records.retain(|r| {
                matches!(
                    r.recording_state.as_str(),
                    "recording" | "complete" | "interrupted" | "failed"
                )
            });
        }
        records.sort_by(|a, b| b.started_at.cmp(&a.started_at).then(b.id.cmp(&a.id)));
        let total = records.len();
        let next = (offset.saturating_add(PAGE) < total).then_some(offset + PAGE);
        let mut page = records
            .into_iter()
            .skip(offset)
            .take(PAGE)
            .collect::<Vec<_>>();
        for record in &mut page {
            if record.recording_state == "recording" {
                let meta =
                    fs::metadata(self.audio(record.id)).map_err(|_| "recording_audio_stat")?;
                record.bytes = meta.len();
                record.duration_ms = record.bytes.saturating_sub(44) * 1000 / (u64::from(RATE) * 4);
            }
        }
        Ok(json!({"items":page,"nextOffset":next,"error":*self.error.lock().unwrap()}))
    }
    fn chunk(&self, id: Uuid, offset: u64) -> Result<Value, String> {
        let mut slot = self.records.lock().unwrap();
        self.load(&mut slot)?;
        let record = slot
            .as_ref()
            .unwrap()
            .get(&id)
            .ok_or("recording_not_found")?;
        if matches!(record.recording_state.as_str(), "none" | "deleted") {
            return Err("recording_not_found".into());
        }
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.audio(id))
            .map_err(|_| "recording_not_found")?;
        let total = file.metadata().map_err(|_| "recording_audio_stat")?.len();
        if offset > total {
            return Err("invalid_recording_offset".into());
        }
        file.seek(SeekFrom::Start(offset))
            .map_err(|_| "recording_audio_seek")?;
        let mut bytes = vec![0; ((total - offset) as usize).min(CHUNK)];
        file.read_exact(&mut bytes)
            .map_err(|_| "recording_audio_read")?;
        Ok(
            json!({"id":id,"offset":offset,"totalBytes":total,"complete":record.recording_state!="recording","audio":base64::engine::general_purpose::STANDARD.encode(bytes)}),
        )
    }
    fn delete(&self, id: Uuid) -> Result<Value, String> {
        let mut slot = self.records.lock().unwrap();
        self.load(&mut slot)?;
        let records = slot.as_mut().unwrap();
        let Some(mut record) = records.get(&id).cloned() else {
            return Ok(json!({"deleted":true}));
        };
        if record.state != "ended" || record.recording_state == "recording" {
            return Err("recording_in_progress".into());
        }
        // Persist the tombstone before unlinking: a crash cannot resurrect a deleted recording.
        record.recording_state = "deleted".into();
        record.bytes = 0;
        record.duration_ms = 0;
        record.recording_error = None;
        record.has_transcript = false;
        self.save(&record)?;
        records.insert(id, record);
        match fs::remove_file(self.audio(id)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("recording_delete_failed".into()),
        }
        match fs::remove_file(self.transcript_path(id)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("transcript_delete_failed".into()),
        }
        File::open(&self.root)
            .and_then(|f| f.sync_all())
            .map_err(|_| "recording_delete_sync")?;
        Ok(json!({"deleted":true}))
    }
    fn transcript(&self, id: Uuid, body: Option<&[u8]>) -> Result<Value, String> {
        #[derive(Serialize, Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Transcript {
            text: String,
            locale: String,
        }
        let mut slot = self.records.lock().unwrap();
        self.load(&mut slot)?;
        let records = slot.as_mut().unwrap();
        let mut record = records.get(&id).cloned().ok_or("recording_not_found")?;
        if matches!(record.recording_state.as_str(), "none" | "deleted") {
            return Err("recording_not_found".into());
        }
        if let Some(body) = body {
            let transcript: Transcript =
                serde_json::from_slice(body).map_err(|_| "invalid_transcript")?;
            if transcript.text.len() > 48000
                || transcript.locale.is_empty()
                || transcript.locale.len() > 64
                || !transcript
                    .locale
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
            {
                return Err("invalid_transcript_size_or_locale".into());
            }
            if record.state != "ended" {
                return Err("recording_in_progress".into());
            }
            private_write(
                &self.transcript_path(id),
                &serde_json::to_vec(&transcript).map_err(|_| "transcript_encode")?,
            )?;
            record.has_transcript = true;
            self.save(&record)?;
            records.insert(id, record);
            return Ok(json!({"saved":true}));
        }
        match fs::symlink_metadata(self.transcript_path(id)) {
            Ok(_) => {
                let transcript: Transcript =
                    serde_json::from_slice(&private_read(&self.transcript_path(id))?)
                        .map_err(|_| "invalid_transcript")?;
                Ok(json!({"transcript":transcript}))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(json!({"transcript":null})),
            Err(_) => Err("transcript_read_failed".into()),
        }
    }
    pub fn route(&self, method: &Method, path: &str, body: &[u8]) -> Option<(u16, Value)> {
        let parts = path.trim_start_matches('/').split('/').collect::<Vec<_>>();
        if parts.get(0) != Some(&"api")
            || !matches!(parts.get(1), Some(&"recordings") | Some(&"call-history"))
        {
            return None;
        }
        let recordings = parts[1] == "recordings";
        let result = match (method, parts.as_slice()) {
            (&Method::Get, [_, _]) => self.snapshot(recordings, 0),
            (&Method::Get, [_, _, "page", offset]) => offset
                .parse::<usize>()
                .map_err(|_| "invalid_history_offset".to_string())
                .and_then(|offset| self.snapshot(recordings, offset)),
            (&Method::Get, [_, "recordings", id, "audio", offset]) => Uuid::parse_str(id)
                .map_err(|_| "invalid_recording_id".to_string())
                .and_then(|id| {
                    offset
                        .parse::<u64>()
                        .map_err(|_| "invalid_recording_offset".to_string())
                        .and_then(|offset| self.chunk(id, offset))
                }),
            (&Method::Delete, [_, "recordings", id]) => Uuid::parse_str(id)
                .map_err(|_| "invalid_recording_id".to_string())
                .and_then(|id| self.delete(id)),
            (&Method::Get, [_, "recordings", id, "transcript"]) => Uuid::parse_str(id)
                .map_err(|_| "invalid_recording_id".to_string())
                .and_then(|id| self.transcript(id, None)),
            (&Method::Put, [_, "recordings", id, "transcript"]) => Uuid::parse_str(id)
                .map_err(|_| "invalid_recording_id".to_string())
                .and_then(|id| self.transcript(id, Some(body))),
            _ => return Some((404, json!({"ok":false,"error":"recording_route_not_found"}))),
        };
        Some(match result {
            Ok(data) => (200, json!({"ok":true,"data":data})),
            Err(error) => {
                let status = match error.as_str() {
                    "recording_not_found" => 404,
                    "recording_in_progress" => 409,
                    e if e.starts_with("invalid_") => 400,
                    _ => 503,
                };
                (status, json!({"ok":false,"error":error}))
            }
        })
    }
}
fn wav_header(file: &mut File, bytes: u64) -> Result<(), String> {
    let size = u32::try_from(bytes)
        .ok()
        .filter(|v| *v <= u32::MAX - 36)
        .ok_or("recording_size_limit")?;
    let mut header = Vec::with_capacity(44);
    header.extend_from_slice(b"RIFF");
    header.extend_from_slice(&(size + 36).to_le_bytes());
    header.extend_from_slice(b"WAVEfmt ");
    header.extend_from_slice(&16u32.to_le_bytes());
    header.extend_from_slice(&1u16.to_le_bytes());
    header.extend_from_slice(&2u16.to_le_bytes());
    header.extend_from_slice(&RATE.to_le_bytes());
    header.extend_from_slice(&(RATE * 4).to_le_bytes());
    header.extend_from_slice(&4u16.to_le_bytes());
    header.extend_from_slice(&16u16.to_le_bytes());
    header.extend_from_slice(b"data");
    header.extend_from_slice(&size.to_le_bytes());
    file.seek(SeekFrom::Start(0))
        .and_then(|_| file.write_all(&header))
        .and_then(|_| file.seek(SeekFrom::End(0)))
        .map_err(|_| "recording_header_write")?;
    Ok(())
}
fn write_audio(
    mut file: File,
    receiver: mpsc::Receiver<(usize, Vec<u8>)>,
    overflow: &AtomicBool,
    reserve: u64,
) -> Result<(), String> {
    let mut queues = [VecDeque::<i16>::new(), VecDeque::<i16>::new()];
    let mut bytes = 0u64;
    let mut next = Instant::now() + Duration::from_millis(20);
    let mut checkpoint = Instant::now();
    let result = (|| {
        loop {
            if overflow.load(Ordering::Acquire) {
                return Err("recording_queue_overflow".into());
            }
            match receiver.recv_timeout(next.saturating_duration_since(Instant::now())) {
                Ok((channel, pcm)) => {
                    queues[channel].extend(
                        pcm.chunks_exact(2)
                            .map(|s| i16::from_le_bytes([s[0], s[1]])),
                    );
                    if queues[channel].len() > RATE as usize * 2 {
                        return Err("recording_audio_backlog".into());
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    while queues.iter().any(|q| !q.is_empty()) {
                        write_frame(&mut file, &mut queues, &mut bytes)?;
                    }
                    break;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            if Instant::now() >= next {
                write_frame(&mut file, &mut queues, &mut bytes)?;
                next += Duration::from_millis(20);
            }
            if checkpoint.elapsed() >= Duration::from_secs(1) {
                ensure_space(&file, reserve)?;
                wav_header(&mut file, bytes)?;
                file.sync_data().map_err(|_| "recording_audio_sync")?;
                checkpoint = Instant::now();
            }
        }
        Ok(())
    })();
    wav_header(&mut file, bytes)?;
    file.sync_all().map_err(|_| "recording_audio_sync")?;
    result
}
fn write_frame(
    file: &mut File,
    queues: &mut [VecDeque<i16>; 2],
    bytes: &mut u64,
) -> Result<(), String> {
    let mut frame = [0u8; 640];
    for sample in 0..160 {
        for channel in 0..2 {
            let value = queues[channel].pop_front().unwrap_or(0).to_le_bytes();
            frame[sample * 4 + channel * 2..sample * 4 + channel * 2 + 2].copy_from_slice(&value);
        }
    }
    file.write_all(&frame)
        .map_err(|_| "recording_audio_write")?;
    *bytes += 640;
    Ok(())
}
fn ensure_space(file: &File, reserve: u64) -> Result<(), String> {
    use std::os::fd::AsRawFd;
    let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    if unsafe { libc::fstatvfs(file.as_raw_fd(), stats.as_mut_ptr()) } != 0 {
        return Err("recording_storage_stat".into());
    }
    let stats = unsafe { stats.assume_init() };
    if (stats.f_bavail as u64).saturating_mul(stats.f_frsize as u64) < reserve {
        return Err("recording_storage_full".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn store() -> Arc<Recordings> {
        Recordings::at(&std::env::temp_dir().join(format!("openu60-recordings-{}", Uuid::new_v4())))
    }
    fn ended(store: &Recordings, id: Uuid) {
        store
            .observe(
                id,
                Some("+12025550123".into()),
                true,
                "ended",
                200,
                Some("remote_hangup"),
                None,
            )
            .unwrap();
    }
    #[test]
    fn line_is_frozen_at_call_creation_including_unknown_legacy_records() {
        let store = store(); let first = Uuid::new_v4(); let legacy = Uuid::new_v4();
        let a = crate::cellular_line::CellularLine { iccid: "890000000000000001".into(), number: Some("+12025550101".into()), source: "manual".into() };
        let b = crate::cellular_line::CellularLine { iccid: "890000000000000002".into(), number: Some("+12025550102".into()), source: "sim".into() };
        store.observe(first, None, false, "dialing", 100, None, Some(a.clone())).unwrap();
        store.observe(first, None, false, "active", 105, None, Some(b.clone())).unwrap();
        ended(&store, first);
        store.observe(legacy, None, true, "ringing", 110, None, None).unwrap();
        store.observe(legacy, None, true, "ended", 120, None, Some(b)).unwrap();
        let restored = Recordings::at(&store.root);
        let items = restored.snapshot(false, 0).unwrap()["items"].as_array().unwrap().clone();
        assert_eq!(items.iter().find(|item| item["id"] == first.to_string()).unwrap()["line"], json!(a));
        assert!(items.iter().find(|item| item["id"] == legacy.to_string()).unwrap().get("line").is_none());
        fs::remove_dir_all(&store.root).unwrap();
    }
    #[test]
    fn device_attribution_survives_restart_and_cannot_change_owners() {
        let store = store(); let id = Uuid::new_v4();
        store.observe(id, None, true, "ringing", 90, None, None).unwrap();
        assert!(store.snapshot(false,0).unwrap()["items"][0].get("phone").is_none());
        let phone = CallPhone {id:Uuid::new_v4(),name:"iPhone 16 Pro".into(),model:"iPhone17,1".into()};
        store.assign_phone(id,&phone).unwrap();
        store.observe(id,None,true,"active",100,None,None).unwrap();
        store.observe(id,None,true,"active",120,None,None).unwrap();
        ended(&store,id);
        let recovered = Recordings::at(&store.root);
        let history = recovered.snapshot(false,0).unwrap();
        assert_eq!(history["items"][0]["phone"],serde_json::to_value(&phone).unwrap());
        assert_eq!(history["items"][0]["answeredAt"],100);
        recovered.assign_phone(id,&phone).unwrap();
        let other = CallPhone {id:Uuid::new_v4(),..phone};
        assert_eq!(recovered.assign_phone(id,&other).unwrap_err(),"recording_phone_conflict");
        fs::remove_dir_all(&store.root).unwrap();
    }
    #[test]
    fn both_sides_are_saved_in_distinct_channels_and_download_in_bounded_chunks() {
        let store = store();
        let id = Uuid::new_v4();
        store.observe(id, None, true, "active", 100, None, None).unwrap();
        let sink = store.start(id).unwrap();
        sink.push(0, &[1000i16.to_le_bytes(); 160].concat());
        sink.push(1, &[(-2000i16).to_le_bytes(); 160].concat());
        drop(sink);
        ended(&store, id);
        store.stop(id);
        for _ in 0..100 {
            if store.snapshot(true, 0).unwrap()["items"][0]["recordingState"] == "complete" {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let data = fs::read(store.audio(id)).unwrap();
        assert_eq!(&data[..4], b"RIFF");
        assert_eq!(
            u32::from_le_bytes(data[40..44].try_into().unwrap()) as usize,
            data.len() - 44
        );
        let samples = data[44..].chunks_exact(4).collect::<Vec<_>>();
        assert!(samples
            .iter()
            .any(|s| i16::from_le_bytes([s[0], s[1]]) == 1000));
        assert!(samples
            .iter()
            .any(|s| i16::from_le_bytes([s[2], s[3]]) == -2000));
        let chunk = store.chunk(id, 0).unwrap();
        assert!(chunk["complete"].as_bool().unwrap());
        assert_eq!(
            base64::engine::general_purpose::STANDARD
                .decode(chunk["audio"].as_str().unwrap())
                .unwrap(),
            data
        );
        assert!(store.chunk(id, data.len() as u64 + 1).is_err());
        fs::remove_dir_all(&store.root).unwrap();
    }
    #[test]
    fn interrupted_audio_is_recovered_and_deletion_retains_call_history() {
        let store = store();
        let id = Uuid::new_v4();
        store.observe(id, None, false, "active", 100, None, None).unwrap();
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(store.audio(id))
            .unwrap();
        wav_header(&mut file, 0).unwrap();
        file.write_all(&[0; 640]).unwrap();
        drop(file);
        store.update_recording(id, "recording", None).unwrap();
        let recovered = Recordings::at(&store.root);
        let history = recovered.snapshot(false, 0).unwrap();
        assert_eq!(history["items"][0]["recordingState"], "interrupted");
        assert_eq!(history["items"][0]["bytes"], 684);
        recovered.delete(id).unwrap();
        recovered.delete(id).unwrap();
        assert_eq!(
            recovered.snapshot(true, 0).unwrap()["items"]
                .as_array()
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            recovered.snapshot(false, 0).unwrap()["items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(!recovered.audio(id).exists());
        fs::remove_dir_all(&store.root).unwrap();
    }
    #[test]
    fn active_recordings_cannot_be_deleted_and_routes_reject_invalid_ids() {
        let store = store();
        let id = Uuid::new_v4();
        store.observe(id, None, true, "ringing", 100, None, None).unwrap();
        assert_eq!(store.delete(id).unwrap_err(), "recording_in_progress");
        assert_eq!(
            store
                .route(&Method::Delete, "/api/recordings/bad", b"")
                .unwrap()
                .0,
            400
        );
        assert!(store.snapshot(true, 0).unwrap()["items"]
            .as_array()
            .unwrap()
            .is_empty());
        fs::remove_dir_all(&store.root).unwrap();
    }
    #[test]
    fn storage_reserve_fails_explicitly_and_does_not_remove_audio() {
        let store = store();
        let id = Uuid::new_v4();
        store.observe(id, None, true, "active", 100, None, None).unwrap();
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(store.audio(id))
            .unwrap();
        assert_eq!(
            ensure_space(&file, u64::MAX).unwrap_err(),
            "recording_storage_full"
        );
        assert!(store.audio(id).is_file());
        fs::remove_dir_all(&store.root).unwrap();
    }
    #[test]
    fn chunks_are_bounded_and_transcripts_are_shared_and_deleted_with_audio() {
        let store = store();
        let id = Uuid::new_v4();
        ended(&store, id);
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(store.audio(id))
            .unwrap();
        wav_header(&mut file, 128000).unwrap();
        file.write_all(&vec![0; 128000]).unwrap();
        drop(file);
        store.update_recording(id, "complete", None).unwrap();
        let first = store.chunk(id, 0).unwrap();
        assert_eq!(
            base64::engine::general_purpose::STANDARD
                .decode(first["audio"].as_str().unwrap())
                .unwrap()
                .len(),
            CHUNK
        );
        let last = store.chunk(id, 65536).unwrap();
        assert_eq!(
            base64::engine::general_purpose::STANDARD
                .decode(last["audio"].as_str().unwrap())
                .unwrap()
                .len(),
            128044 - CHUNK
        );
        assert!(store.transcript(id, None).unwrap()["transcript"].is_null());
        store
            .transcript(
                id,
                Some(br#"{"text":"Synthetic transcript","locale":"en-US"}"#),
            )
            .unwrap();
        assert_eq!(
            store.transcript(id, None).unwrap()["transcript"]["text"],
            "Synthetic transcript"
        );
        assert_eq!(
            store.snapshot(true, 0).unwrap()["items"][0]["hasTranscript"],
            true
        );
        let excessive =
            serde_json::to_vec(&json!({"text":"a".repeat(48001),"locale":"en-US"})).unwrap();
        assert!(store.transcript(id, Some(&excessive)).is_err());
        store.delete(id).unwrap();
        assert!(!store.transcript_path(id).exists());
        assert!(store.transcript(id, None).is_err());
        fs::remove_dir_all(&store.root).unwrap();
    }
}
