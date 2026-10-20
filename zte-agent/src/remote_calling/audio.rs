use sha2::{Digest, Sha256};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use tokio::net::UnixDatagram;

const HELPER: &str = "/usr/bin/zte_route_hal_voice_test";
const SHIM: &str = "/data/openu60-calling/libopenu60-audio.so";
const HELPER_SHA: &str = "14f02d6d8af581cf08102be83ecd08f332d529a5a4a38efc455e832fcd672f11";

pub fn available() -> Result<(), &'static str> {
    for path in [HELPER, SHIM] {
        let meta = std::fs::symlink_metadata(path).map_err(|_| "audio_adapter_not_installed")?;
        if !meta.is_file() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o022 != 0 {
            return Err("audio_adapter_permissions");
        }
    }
    let mut input = std::fs::File::open(HELPER).map_err(|_| "audio_helper_unavailable")?;
    let mut bytes = Vec::new();
    input
        .by_ref()
        .take(1024 * 1024)
        .read_to_end(&mut bytes)
        .map_err(|_| "audio_helper_read")?;
    if format!("{:x}", Sha256::digest(bytes)) != HELPER_SHA {
        return Err("unsupported_audio_helper");
    }
    if !Path::new("/tmp/mbb_agm_server_ready").exists() {
        return Err("audio_graph_not_ready");
    }
    Ok(())
}

pub struct AudioBridge {
    pub socket: UnixDatagram,
    child: Child,
}
impl AudioBridge {
    pub fn start() -> Result<Self, &'static str> {
        available()?;
        let (parent, child) =
            std::os::unix::net::UnixDatagram::pair().map_err(|_| "audio_socket")?;
        parent.set_nonblocking(true).map_err(|_| "audio_socket")?;
        let socket = UnixDatagram::from_std(parent).map_err(|_| "audio_socket")?;
        let fd = child.as_raw_fd();
        let mut command = Command::new(HELPER);
        command
            .args([
                "-i",
                "11C05000",
                "-d",
                "2,2147483664",
                "-p",
                "dummy",
                "-r",
                "dummy",
                "-t",
                "0",
            ])
            .env_clear()
            .env("PATH", "/usr/bin:/usr/sbin:/bin:/sbin")
            .env("LD_PRELOAD", SHIM)
            .env("OPENU60_AUDIO_FD", fd.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(move || {
                if libc::fcntl(fd, libc::F_SETFD, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                #[cfg(target_os = "linux")]
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child_process = command.spawn().map_err(|_| "audio_helper_start")?;
        drop(child);
        Ok(Self {
            socket,
            child: child_process,
        })
    }
    pub fn check(&mut self) -> Result<(), &'static str> {
        match self.child.try_wait() {
            Ok(None) => Ok(()),
            Ok(Some(_)) => Err("audio_helper_exited"),
            Err(_) => Err("audio_helper_status"),
        }
    }
}
impl Drop for AudioBridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn frame(kind: u8, payload: &[u8]) -> Result<Vec<u8>, &'static str> {
    if payload.is_empty() || payload.len() > 8192 {
        return Err("invalid_audio_frame");
    }
    let mut packet = Vec::with_capacity(8 + payload.len());
    packet.extend_from_slice(b"OU60");
    packet.extend_from_slice(&[kind, 0]);
    packet.extend_from_slice(&(payload.len() as u16).to_le_bytes());
    packet.extend_from_slice(payload);
    Ok(packet)
}
pub fn parse(packet: &[u8]) -> Result<(u8, &[u8]), &'static str> {
    if packet.len() < 8 || &packet[..4] != b"OU60" || packet[5] != 0 {
        return Err("invalid_audio_frame");
    }
    let size = u16::from_le_bytes([packet[6], packet[7]]) as usize;
    if size > 8192 || size + 8 != packet.len() {
        return Err("invalid_audio_frame");
    }
    Ok((packet[4], &packet[8..]))
}
