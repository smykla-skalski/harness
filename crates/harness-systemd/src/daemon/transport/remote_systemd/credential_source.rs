//! Preflight validation for the credential copied into the managed unit.

use std::fs::{self, Metadata, OpenOptions};
use std::io::Read as _;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};

use super::super::remote_systemd_lifecycle::validate_trusted_read_source;

const MAX_CREDENTIAL_BYTES: u64 = 64 * 1024;

pub(super) fn validate_companion_credential_source(path: &Path) -> Result<(), CliError> {
    let initial = fs::symlink_metadata(path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "inspect companion credential source {}: {error}",
            path.display()
        ))
    })?;
    validate_metadata(path, &initial)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "open companion credential source {}: {error}",
                path.display()
            ))
        })?;
    let opened = file.metadata().map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "inspect open companion credential source {}: {error}",
            path.display()
        ))
    })?;
    validate_metadata(path, &opened)?;
    validate_trusted_read_source(path, "companion credential source", &opened)?;
    if initial.dev() != opened.dev() || initial.ino() != opened.ino() {
        return Err(CliErrorKind::workflow_io(format!(
            "companion credential source changed while opening: {}",
            path.display()
        ))
        .into());
    }
    let mut contents = String::new();
    file.take(MAX_CREDENTIAL_BYTES + 1)
        .read_to_string(&mut contents)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "read companion credential source {}: {error}",
                path.display()
            ))
        })?;
    validate_contents(path, &contents)
}

fn validate_metadata(path: &Path, metadata: &Metadata) -> Result<(), CliError> {
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CliErrorKind::workflow_io(format!(
            "companion credential source is not a regular file: {}",
            path.display()
        ))
        .into());
    }
    let mode = metadata.mode() & 0o7777;
    if mode & 0o400 == 0 || mode & 0o077 != 0 {
        return Err(CliErrorKind::workflow_io(format!(
            "companion credential source must be owner-readable and private, found mode {mode:04o}: {}",
            path.display()
        ))
        .into());
    }
    Ok(())
}

fn validate_contents(path: &Path, contents: &str) -> Result<(), CliError> {
    if contents.len() as u64 > MAX_CREDENTIAL_BYTES {
        return Err(CliErrorKind::workflow_parse(format!(
            "companion credential source exceeds the maximum of \
             {MAX_CREDENTIAL_BYTES} bytes: {}",
            path.display()
        ))
        .into());
    }
    let token = contents.trim();
    if token.len() < 32 {
        return Err(CliErrorKind::workflow_parse(format!(
            "companion credential source must contain at least 32 bytes: {}",
            path.display()
        ))
        .into());
    }
    if !token.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err(CliErrorKind::workflow_parse(format!(
            "companion credential source contains whitespace, control, or header-unsafe characters: {}",
            path.display()
        ))
        .into());
    }
    Ok(())
}

#[cfg(test)]
pub(crate) fn validate_companion_credential_source_for_tests(path: &Path) -> Result<(), CliError> {
    validate_companion_credential_source(path)
}
