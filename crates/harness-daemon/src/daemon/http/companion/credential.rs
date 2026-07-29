//! Safe loading for the daemon-to-panel bearer credential.

use std::env;
#[cfg(unix)]
use std::fs::OpenOptions;
use std::fs::{File, Metadata};
use std::io::{self, Read as _};
use std::path::{Path, PathBuf};

use super::CompanionConfigError;

const MAX_CREDENTIAL_BYTES: u64 = 64 * 1024;

pub(super) fn read_private_file(path: &Path) -> Result<String, CompanionConfigError> {
    let display_path = path.display().to_string();
    let file = open_private_file(path).map_err(|error| {
        CompanionConfigError::AuthTokenUnreadable(format!("{display_path}: {error}"))
    })?;
    let metadata = file.metadata().map_err(|error| {
        CompanionConfigError::AuthTokenUnreadable(format!("{display_path}: {error}"))
    })?;
    if !metadata.is_file() {
        return Err(CompanionConfigError::AuthTokenNotRegularFile(display_path));
    }
    validate_private_permissions(path, &metadata)?;
    read_bounded(file, path)
}

fn read_bounded(file: File, path: &Path) -> Result<String, CompanionConfigError> {
    let display_path = path.display().to_string();
    let mut contents = String::new();
    file.take(MAX_CREDENTIAL_BYTES + 1)
        .read_to_string(&mut contents)
        .map_err(|error| {
            CompanionConfigError::AuthTokenUnreadable(format!("{display_path}: {error}"))
        })?;
    if contents.len() as u64 > MAX_CREDENTIAL_BYTES {
        return Err(CompanionConfigError::AuthTokenUnreadable(format!(
            "{display_path}: credential exceeds {MAX_CREDENTIAL_BYTES} bytes"
        )));
    }
    Ok(contents)
}

#[cfg(unix)]
fn open_private_file(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt as _;

    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
}

#[cfg(not(unix))]
fn open_private_file(path: &Path) -> io::Result<File> {
    File::open(path)
}

#[cfg(unix)]
fn validate_private_permissions(
    path: &Path,
    metadata: &Metadata,
) -> Result<(), CompanionConfigError> {
    use std::os::unix::fs::MetadataExt as _;

    let mode = metadata.mode() & 0o777;
    let credential_directory = env::var_os("CREDENTIALS_DIRECTORY").map(PathBuf::from);
    if credential_permissions_are_safe(path, mode, metadata.uid(), credential_directory.as_deref())
    {
        return Ok(());
    }
    Err(CompanionConfigError::AuthTokenPermissionsTooOpen(
        path.display().to_string(),
    ))
}

#[cfg(unix)]
fn credential_permissions_are_safe(
    path: &Path,
    mode: u32,
    owner_uid: u32,
    credential_directory: Option<&Path>,
) -> bool {
    let private_to_owner = mode.trailing_zeros() >= 6;
    let safe_systemd_acl = owner_uid == 0
        && mode.trailing_zeros() >= 5
        && credential_directory.is_some_and(|directory| {
            directory.is_absolute()
                && path.parent() == Some(directory)
                && path.file_name().is_some()
        });
    private_to_owner || safe_systemd_acl
}

#[cfg(not(unix))]
fn validate_private_permissions(
    _path: &Path,
    _metadata: &Metadata,
) -> Result<(), CompanionConfigError> {
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use std::path::Path;

    use super::credential_permissions_are_safe;

    #[test]
    fn only_root_owned_direct_systemd_credentials_may_use_an_acl_mask() {
        let directory = Path::new("/run/credentials/harness.service");
        let credential = directory.join("companion-auth-token");

        assert!(credential_permissions_are_safe(
            &credential,
            0o440,
            0,
            Some(directory)
        ));
        assert!(!credential_permissions_are_safe(
            &credential,
            0o440,
            501,
            Some(directory)
        ));
        assert!(!credential_permissions_are_safe(
            &directory.join("nested/token"),
            0o440,
            0,
            Some(directory)
        ));
        assert!(!credential_permissions_are_safe(
            &credential,
            0o460,
            0,
            Some(directory)
        ));
        assert!(credential_permissions_are_safe(
            Path::new("/tmp/private"),
            0o600,
            501,
            None
        ));
    }
}
