use std::fs::{File, Metadata, OpenOptions};
use std::io::{Read as _, Result as IoResult};
use std::path::Path;

use crate::SybraGatewayConfigError;

const MAX_TOKEN_BYTES: u64 = 64 * 1024;

pub(crate) fn read_private_file(path: &Path) -> Result<String, SybraGatewayConfigError> {
    let display = path.display().to_string();
    let file = open_private_file(path)
        .map_err(|error| SybraGatewayConfigError::TokenUnreadable(format!("{display}: {error}")))?;
    let metadata = file
        .metadata()
        .map_err(|error| SybraGatewayConfigError::TokenUnreadable(format!("{display}: {error}")))?;
    if !metadata.is_file() {
        return Err(SybraGatewayConfigError::TokenNotRegularFile(display));
    }
    validate_private_permissions(path, &metadata)?;
    read_bounded(file, path)
}

fn read_bounded(file: File, path: &Path) -> Result<String, SybraGatewayConfigError> {
    let display = path.display().to_string();
    let mut contents = String::new();
    file.take(MAX_TOKEN_BYTES + 1)
        .read_to_string(&mut contents)
        .map_err(|error| SybraGatewayConfigError::TokenUnreadable(format!("{display}: {error}")))?;
    if contents.len() as u64 > MAX_TOKEN_BYTES {
        return Err(SybraGatewayConfigError::TokenUnreadable(format!(
            "{display}: credential exceeds {MAX_TOKEN_BYTES} bytes"
        )));
    }
    Ok(contents)
}

#[cfg(unix)]
fn open_private_file(path: &Path) -> IoResult<File> {
    use std::os::unix::fs::OpenOptionsExt as _;

    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
}

#[cfg(not(unix))]
fn open_private_file(path: &Path) -> IoResult<File> {
    File::open(path)
}

#[cfg(unix)]
fn validate_private_permissions(
    path: &Path,
    metadata: &Metadata,
) -> Result<(), SybraGatewayConfigError> {
    use std::os::unix::fs::MetadataExt as _;

    if metadata.mode().trailing_zeros() >= 6 {
        return Ok(());
    }
    Err(SybraGatewayConfigError::TokenPermissionsTooOpen(
        path.display().to_string(),
    ))
}

#[cfg(not(unix))]
fn validate_private_permissions(
    _path: &Path,
    _metadata: &Metadata,
) -> Result<(), SybraGatewayConfigError> {
    Ok(())
}
