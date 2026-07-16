use std::fs::{DirBuilder, File, Metadata, OpenOptions, Permissions};
use std::io::{ErrorKind, Read as _};
use std::os::unix::fs::{
    DirBuilderExt as _, MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _,
};
use std::path::{Path, PathBuf};

use fs_err as fs;
use nix::unistd::{Gid, Uid, fchown};

use crate::errors::CliError;

use super::super::storage::{open_directory, sync_directory};
use super::super::{io_error, trusted_gid, trusted_owner, trusted_uid};

pub(super) struct OpenToken {
    pub(super) file: File,
    pub(super) path: PathBuf,
}

pub(super) fn create_token_directory(path: &Path, parent: &Path) -> Result<(), CliError> {
    let mut builder = DirBuilder::new();
    builder.mode(0o700);
    builder.create(path).map_err(|error| {
        io_error(format!(
            "create runtime permit token directory {}: {error}",
            path.display()
        ))
    })?;
    let result = secure_token_directory(path, parent);
    if result.is_err() {
        remove_empty_token_directory(path, parent);
    }
    result
}

fn secure_token_directory(path: &Path, parent: &Path) -> Result<(), CliError> {
    let directory = open_directory(path)?;
    let (uid, gid) = trusted_owner();
    fchown(
        &directory,
        Some(Uid::from_raw(uid)),
        Some(Gid::from_raw(gid)),
    )
    .map_err(|error| {
        io_error(format!(
            "set runtime permit token directory ownership {}: {error}",
            path.display()
        ))
    })?;
    directory
        .set_permissions(Permissions::from_mode(0o700))
        .map_err(|error| {
            io_error(format!(
                "set runtime permit token directory permissions {}: {error}",
                path.display()
            ))
        })?;
    directory.sync_all().map_err(|error| {
        io_error(format!(
            "sync runtime permit token directory {}: {error}",
            path.display()
        ))
    })?;
    validate_token_directory(
        path,
        &directory.metadata().map_err(|error| {
            io_error(format!(
                "inspect runtime permit token directory {}: {error}",
                path.display()
            ))
        })?,
    )?;
    sync_directory(parent)
}

pub(super) fn inspect_token_directory(path: &Path) -> Result<bool, CliError> {
    let initial = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(io_error(format!(
                "inspect runtime permit token directory {}: {error}",
                path.display()
            )));
        }
    };
    validate_token_directory(path, &initial)?;
    let directory = open_directory(path)?;
    let opened = directory.metadata().map_err(|error| {
        io_error(format!(
            "inspect open runtime permit token directory {}: {error}",
            path.display()
        ))
    })?;
    validate_token_directory(path, &opened)?;
    if initial.dev() != opened.dev() || initial.ino() != opened.ino() {
        return Err(io_error(format!(
            "runtime permit token directory changed while opening: {}",
            path.display()
        )));
    }
    Ok(true)
}

fn validate_token_directory(path: &Path, metadata: &Metadata) -> Result<(), CliError> {
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io_error(format!(
            "runtime permit token path is not a real directory: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() || metadata.gid() != trusted_gid() {
        return Err(io_error(format!(
            "runtime permit token directory has untrusted owner {}:{}: {}",
            metadata.uid(),
            metadata.gid(),
            path.display()
        )));
    }
    if metadata.mode() & 0o7777 != 0o700 {
        return Err(io_error(format!(
            "runtime permit token directory must have mode 0700, found {:04o}: {}",
            metadata.mode() & 0o7777,
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn remove_empty_token_directory(path: &Path, parent: &Path) {
    if fs::remove_dir(path).is_ok() {
        let _ = sync_directory(parent);
    }
}

pub(super) fn open_exact_token(path: &Path) -> Result<Option<OpenToken>, CliError> {
    let initial = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(io_error(format!(
                "inspect runtime permit liveness token {}: {error}",
                path.display()
            )));
        }
    };
    validate_token_metadata(path, &initial)?;
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| {
            io_error(format!(
                "open runtime permit liveness token {}: {error}",
                path.display()
            ))
        })?;
    let opened = file.metadata().map_err(|error| {
        io_error(format!(
            "inspect open runtime permit liveness token {}: {error}",
            path.display()
        ))
    })?;
    validate_token_metadata(path, &opened)?;
    if initial.dev() != opened.dev() || initial.ino() != opened.ino() {
        return Err(io_error(format!(
            "runtime permit liveness token changed while opening: {}",
            path.display()
        )));
    }
    let mut contents = Vec::new();
    file.read_to_end(&mut contents).map_err(|error| {
        io_error(format!(
            "read runtime permit liveness token {}: {error}",
            path.display()
        ))
    })?;
    if !contents.is_empty() {
        return Err(io_error(format!(
            "runtime permit liveness token must be empty: {}",
            path.display()
        )));
    }
    Ok(Some(OpenToken {
        file,
        path: path.to_path_buf(),
    }))
}

pub(super) fn validate_token_metadata(path: &Path, metadata: &Metadata) -> Result<(), CliError> {
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(io_error(format!(
            "runtime permit liveness token is not a regular file: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() || metadata.gid() != trusted_gid() {
        return Err(io_error(format!(
            "runtime permit liveness token has untrusted owner {}:{}: {}",
            metadata.uid(),
            metadata.gid(),
            path.display()
        )));
    }
    if metadata.mode() & 0o7777 != 0o600 || metadata.nlink() != 1 {
        return Err(io_error(format!(
            "runtime permit liveness token must have mode 0600 and one link: {}",
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn remove_open_token(token: &OpenToken, parent: &Path) -> Result<(), CliError> {
    let current = fs::symlink_metadata(&token.path).map_err(|error| {
        io_error(format!(
            "inspect runtime permit liveness token before removal {}: {error}",
            token.path.display()
        ))
    })?;
    validate_token_metadata(&token.path, &current)?;
    let opened = token.file.metadata().map_err(|error| {
        io_error(format!(
            "inspect open runtime permit liveness token before removal {}: {error}",
            token.path.display()
        ))
    })?;
    if current.dev() != opened.dev() || current.ino() != opened.ino() {
        return Err(io_error(format!(
            "runtime permit liveness token changed before removal: {}",
            token.path.display()
        )));
    }
    fs::remove_file(&token.path).map_err(|error| {
        io_error(format!(
            "remove runtime permit liveness token {}: {error}",
            token.path.display()
        ))
    })?;
    sync_directory(parent)
}
