use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

pub fn private_read(path: &Path) -> Result<Vec<u8>, String> {
    let meta = fs::symlink_metadata(path).map_err(|e| format!("private_file_metadata: {e}"))?;
    if !meta.is_file()
        || meta.mode() & 0o077 != 0
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.len() > 262144
    {
        return Err("private_file_permissions".into());
    }
    let mut data = Vec::new();
    File::open(path)
        .map_err(|_| "private_file_open")?
        .take(262145)
        .read_to_end(&mut data)
        .map_err(|_| "private_file_read")?;
    if data.len() > 262144 {
        return Err("private_file_too_large".into());
    }
    Ok(data)
}

pub fn private_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("private_file_parent")?;
    match fs::create_dir(parent) {
        Ok(()) => fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .map_err(|_| "private_directory_permissions")?,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err("private_directory_create".into()),
    }
    let meta = fs::symlink_metadata(parent).map_err(|_| "private_directory_metadata")?;
    if !meta.is_dir() || meta.mode() & 0o077 != 0 || meta.uid() != unsafe { libc::geteuid() } {
        return Err("private_directory_permissions".into());
    }
    match fs::symlink_metadata(path) {
        Ok(_) => {
            private_read(path)?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("private_file_metadata".into()),
    }
    let temporary = parent.join(format!(".{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut output = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|_| "private_file_create")?;
        output.write_all(bytes).map_err(|_| "private_file_write")?;
        output.sync_all().map_err(|_| "private_file_sync")?;
        fs::rename(&temporary, path).map_err(|_| "private_file_rename")?;
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|_| "private_directory_sync")?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}
