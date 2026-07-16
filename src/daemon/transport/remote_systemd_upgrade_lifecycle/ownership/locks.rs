use std::fs::{File, Metadata, OpenOptions, Permissions};
use std::io::{self, ErrorKind};
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::Path;

use fs2::FileExt;

use crate::errors::CliError;

use super::super::files::{io_error, sync_directory};

const LOCK_MODE: u32 = 0o600;

#[derive(Debug)]
pub(super) struct StrictFlockGuard {
    file: File,
}

impl Drop for StrictFlockGuard {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.file);
    }
}

pub(super) fn try_acquire_strict_lock(path: &Path) -> Result<Option<StrictFlockGuard>, CliError> {
    let file = open_or_create_lock(path)?;
    match file.try_lock_exclusive() {
        Ok(()) => Ok(Some(StrictFlockGuard { file })),
        Err(error) if error.kind() == ErrorKind::WouldBlock => Ok(None),
        Err(error) => Err(io_error(format!(
            "acquire remote systemd lifecycle lock {}: {error}",
            path.display()
        ))),
    }
}

fn open_or_create_lock(path: &Path) -> Result<File, CliError> {
    let parent = path.parent().ok_or_else(|| {
        io_error(format!(
            "remote systemd lifecycle lock has no parent: {}",
            path.display()
        ))
    })?;
    match open_new_lock(path) {
        Ok(file) => {
            file.set_permissions(Permissions::from_mode(LOCK_MODE))
                .map_err(|error| lock_error("set permissions on", path, &error))?;
            validate_open_lock(&file, path)?;
            file.sync_all()
                .map_err(|error| lock_error("sync", path, &error))?;
            sync_directory(parent)?;
            Ok(file)
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => open_existing_lock(path),
        Err(error) => Err(lock_error("create", path, &error)),
    }
}

fn open_new_lock(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .mode(LOCK_MODE)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
}

fn open_existing_lock(path: &Path) -> Result<File, CliError> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| lock_error("open", path, &error))?;
    let metadata = inspect_open_lock(&file, path)?;
    if metadata.mode() & 0o7133 != 0 {
        return Err(io_error(format!(
            "remote systemd lifecycle lock has an unsafe mode: {}",
            path.display()
        )));
    }
    if metadata.mode() & 0o7777 != LOCK_MODE {
        file.set_permissions(Permissions::from_mode(LOCK_MODE))
            .map_err(|error| lock_error("repair permissions on", path, &error))?;
        file.sync_all()
            .map_err(|error| lock_error("sync repaired", path, &error))?;
        let parent = path.parent().ok_or_else(|| {
            io_error(format!(
                "remote systemd lifecycle lock has no parent: {}",
                path.display()
            ))
        })?;
        sync_directory(parent)?;
    }
    validate_open_lock(&file, path)?;
    Ok(file)
}

fn validate_open_lock(file: &File, path: &Path) -> Result<(), CliError> {
    let metadata = inspect_open_lock(file, path)?;
    if metadata.mode() & 0o7777 != LOCK_MODE {
        return Err(io_error(format!(
            "remote systemd lifecycle lock must have mode 0600: {}",
            path.display()
        )));
    }
    Ok(())
}

fn inspect_open_lock(file: &File, path: &Path) -> Result<Metadata, CliError> {
    let metadata = file
        .metadata()
        .map_err(|error| lock_error("inspect", path, &error))?;
    if !metadata.is_file() {
        return Err(io_error(format!(
            "remote systemd lifecycle lock is not a regular file: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() {
        return Err(io_error(format!(
            "remote systemd lifecycle lock {} must be owned by uid {}, found uid {}",
            path.display(),
            trusted_uid(),
            metadata.uid()
        )));
    }
    if metadata.nlink() != 1 {
        return Err(io_error(format!(
            "remote systemd lifecycle lock must have exactly one link: {}",
            path.display()
        )));
    }
    if metadata.len() != 0 {
        return Err(io_error(format!(
            "remote systemd lifecycle lock must be empty: {}",
            path.display()
        )));
    }
    Ok(metadata)
}

fn lock_error(operation: &str, path: &Path, error: &io::Error) -> CliError {
    io_error(format!(
        "{operation} remote systemd lifecycle lock {}: {error}",
        path.display()
    ))
}

#[cfg(not(test))]
const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_uid() -> u32 {
    uzers::get_current_uid()
}
