use std::fs::{File, Metadata, OpenOptions};
#[cfg(not(target_os = "linux"))]
use std::io::Error;
use std::io::ErrorKind;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
use std::path::Path;

use fs_err as fs;
#[cfg(target_os = "linux")]
use nix::errno::Errno;
#[cfg(target_os = "linux")]
use nix::fcntl::{FallocateFlags, fallocate};

use crate::errors::CliError;

use super::super::files::{combine_errors, io_error, remove_file_if_exists, sync_directory};

pub(super) fn reserve_file(path: &Path, bytes: u64) -> Result<(), CliError> {
    let parent = path
        .parent()
        .ok_or_else(|| io_error(format!("restore reserve has no parent: {}", path.display())))?;
    fs::create_dir_all(parent).map_err(|error| {
        io_error(format!(
            "create restore reserve parent {}: {error}",
            parent.display()
        ))
    })?;
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| {
            io_error(format!(
                "create restore reserve {}: {error}",
                path.display()
            ))
        })?;
    let length = i64::try_from(bytes)
        .map_err(|_| io_error(format!("restore reserve is too large: {bytes} bytes")))?;
    if let Err(error) = allocate_file(&file, length) {
        let reserve_error = io_error(format!(
            "allocate restore reserve {} ({bytes} bytes): {error}",
            path.display()
        ));
        let cleanup = remove_file_if_exists(path).and_then(|()| sync_directory(parent));
        return Err(combine_errors(
            "preallocate systemd rollback capacity",
            &reserve_error,
            cleanup.err(),
        ));
    }
    file.sync_all()
        .map_err(|error| io_error(format!("sync restore reserve {}: {error}", path.display())))?;
    sync_directory(parent)
}

pub(super) fn reserve_is_sufficient(path: &Path, required: u64) -> Result<bool, CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => Err(io_error(
            format!("restore reserve is not a regular file: {}", path.display()),
        )),
        Ok(metadata) => Ok(reserve_has_bytes(&metadata, required)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error(format!(
            "inspect restore reserve {}: {error}",
            path.display()
        ))),
    }
}

#[cfg(target_os = "linux")]
fn reserve_has_bytes(metadata: &Metadata, required: u64) -> bool {
    metadata.len() >= required && metadata.blocks().saturating_mul(512) >= required
}

#[cfg(not(target_os = "linux"))]
fn reserve_has_bytes(metadata: &Metadata, required: u64) -> bool {
    metadata.len() >= required
}

#[cfg(target_os = "linux")]
fn allocate_file(file: &File, length: i64) -> Result<(), Errno> {
    fallocate(file, FallocateFlags::empty(), 0, length)
}

#[cfg(all(not(target_os = "linux"), test))]
fn allocate_file(file: &File, length: i64) -> Result<(), Error> {
    use std::io::Write as _;

    let mut file = file.try_clone()?;
    let mut remaining = u64::try_from(length).unwrap_or(u64::MAX);
    let block = [0_u8; 64 * 1024];
    let block_length = u64::try_from(block.len()).unwrap_or(u64::MAX);
    while remaining > 0 {
        let length = usize::try_from(remaining.min(block_length)).unwrap_or(block.len());
        file.write_all(&block[..length])?;
        remaining -= u64::try_from(length).unwrap_or(block_length);
    }
    Ok(())
}

#[cfg(all(not(target_os = "linux"), not(test)))]
fn allocate_file(_file: &File, _length: i64) -> Result<(), Error> {
    Err(Error::new(
        ErrorKind::Unsupported,
        "systemd rollback capacity reservation requires Linux fallocate",
    ))
}
