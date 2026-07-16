use std::env::temp_dir;
use std::fs::{File, Metadata, OpenOptions, Permissions};
use std::io::{Error, ErrorKind, Read as _, Write as _};
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::Path;

use fs_err as fs;
use nix::unistd::{Gid, Uid, fchown};
use tempfile::NamedTempFile;

use crate::errors::{CliError, CliErrorKind};

pub(super) fn validate_install_binary(path: &Path) -> Result<(), CliError> {
    validate_trusted_ancestors(path, "configured binary")?;
    let file = open_existing_regular_file(path, "configured binary")?.ok_or_else(|| {
        io_error(format!(
            "configured binary does not exist: {}",
            path.display()
        ))
    })?;
    let metadata = file.metadata().map_err(|error| {
        io_error(format!(
            "inspect configured binary {}: {error}",
            path.display()
        ))
    })?;
    let (owner_id, group_id) = trusted_owner();
    if metadata.uid() != owner_id || metadata.gid() != group_id {
        return Err(io_error(format!(
            "configured binary {} must have trusted ownership {owner_id}:{group_id}, found {}:{}",
            path.display(),
            metadata.uid(),
            metadata.gid()
        )));
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(io_error(format!(
            "configured binary {} must not be group- or world-writable (mode {:04o})",
            path.display(),
            metadata.mode() & 0o7777
        )));
    }
    if metadata.mode() & 0o111 == 0 {
        return Err(io_error(format!(
            "configured binary is not executable: {}",
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn write_unit_if_missing(
    path: &Path,
    contents: &str,
    unit: &str,
    mode: u32,
) -> Result<bool, CliError> {
    validate_trusted_ancestors(path, "systemd unit")?;
    if let Some(file) = open_existing_regular_file(path, "systemd unit")? {
        secure_existing_unit(file, path, contents, unit, mode)?;
        sync_parent(path)?;
        return Ok(false);
    }
    let parent = create_parent(path, "systemd unit")?;
    let temporary = prepare_temporary(parent, path, contents, mode)?;
    match temporary.persist_noclobber(path) {
        Ok(_) => {
            sync_directory(parent)?;
            Ok(true)
        }
        Err(error) if error.error.kind() == ErrorKind::AlreadyExists => {
            let file = open_existing_regular_file(path, "systemd unit")?.ok_or_else(|| {
                io_error(format!(
                    "systemd unit {} disappeared during installation",
                    path.display()
                ))
            })?;
            secure_existing_unit(file, path, contents, unit, mode)?;
            sync_parent(path)?;
            Ok(false)
        }
        Err(error) => Err(persist_error(path, &error.error)),
    }
}

pub(super) fn write_if_missing(path: &Path, contents: &str, mode: u32) -> Result<bool, CliError> {
    validate_trusted_ancestors(path, "environment file")?;
    if let Some(file) = open_existing_regular_file(path, "environment file")? {
        apply_trusted_metadata(&file, path, mode)?;
        sync_parent(path)?;
        return Ok(false);
    }
    let parent = create_parent(path, "environment file")?;
    let temporary = prepare_temporary(parent, path, contents, mode)?;
    match temporary.persist_noclobber(path) {
        Ok(_) => {
            sync_directory(parent)?;
            Ok(true)
        }
        Err(error) if error.error.kind() == ErrorKind::AlreadyExists => {
            let file = open_existing_regular_file(path, "environment file")?.ok_or_else(|| {
                io_error(format!(
                    "environment file {} disappeared during installation",
                    path.display()
                ))
            })?;
            apply_trusted_metadata(&file, path, mode)?;
            sync_parent(path)?;
            Ok(false)
        }
        Err(error) => Err(persist_error(path, &error.error)),
    }
}

pub(super) fn validate_install_environment(path: &Path) -> Result<(), CliError> {
    let mut file = open_existing_regular_file(path, "environment file")?.ok_or_else(|| {
        io_error(format!(
            "systemd environment file disappeared before validation: {}",
            path.display()
        ))
    })?;
    let mut contents = String::new();
    file.read_to_string(&mut contents).map_err(|error| {
        io_error(format!(
            "read systemd environment file {}: {error}",
            path.display()
        ))
    })?;
    for line in contents.lines() {
        let line = line.trim_start();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        let Some((name, _)) = line.split_once('=') else {
            return Err(io_error(format!(
                "systemd environment contains an invalid assignment: {line}"
            )));
        };
        if matches!(
            name.trim(),
            "HARNESS_DAEMON_DATA_HOME"
                | "XDG_DATA_HOME"
                | "STATE_DIRECTORY"
                | "HARNESS_DAEMON_OWNERSHIP"
        ) {
            return Err(io_error(format!(
                "systemd environment must not override protected variable {}",
                name.trim()
            )));
        }
    }
    Ok(())
}

pub(super) fn read_trusted_managed_file(
    path: &Path,
    label: &str,
) -> Result<Option<String>, CliError> {
    validate_trusted_ancestors(path, label)?;
    let Some(mut file) = open_existing_regular_file(path, label)? else {
        return Ok(None);
    };
    let metadata = file.metadata().map_err(|error| {
        io_error(format!(
            "inspect managed {label} {}: {error}",
            path.display()
        ))
    })?;
    let (owner_id, group_id) = trusted_owner();
    if metadata.uid() != owner_id || metadata.gid() != group_id {
        return Err(io_error(format!(
            "managed {label} {} has untrusted ownership {}:{}",
            path.display(),
            metadata.uid(),
            metadata.gid()
        )));
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(io_error(format!(
            "managed {label} {} is group- or world-writable (mode {:04o})",
            path.display(),
            metadata.mode() & 0o7777
        )));
    }
    let mut contents = String::new();
    file.read_to_string(&mut contents)
        .map_err(|error| io_error(format!("read managed {label} {}: {error}", path.display())))?;
    Ok(Some(contents))
}

fn secure_existing_unit(
    mut file: File,
    path: &Path,
    expected: &str,
    unit: &str,
    mode: u32,
) -> Result<(), CliError> {
    let mut existing = String::new();
    file.read_to_string(&mut existing).map_err(|error| {
        io_error(format!(
            "read existing systemd unit {}: {error}",
            path.display()
        ))
    })?;
    if existing != expected {
        return Err(CliErrorKind::workflow_parse(format!(
            "existing unit {unit} differs from the requested installation; keep it active and use harness-systemd upgrade so binary, unit, and database state are rollback-protected"
        ))
        .into());
    }
    apply_trusted_metadata(&file, path, mode)
}

fn open_existing_regular_file(path: &Path, label: &str) -> Result<Option<File>, CliError> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) if error.raw_os_error() == Some(libc::ELOOP) => {
            return Err(io_error(format!(
                "refusing symbolic link {label} {}",
                path.display()
            )));
        }
        Err(error) => {
            return Err(io_error(format!(
                "open regular {label} {}: {error}",
                path.display()
            )));
        }
    };
    if file
        .metadata()
        .map_err(|error| io_error(format!("inspect open {label} {}: {error}", path.display())))?
        .is_file()
    {
        Ok(Some(file))
    } else {
        Err(io_error(format!(
            "{label} {} is not a regular file",
            path.display()
        )))
    }
}

fn apply_trusted_metadata(file: &File, path: &Path, mode: u32) -> Result<(), CliError> {
    let (uid, gid) = trusted_owner();
    fchown(file, Some(Uid::from_raw(uid)), Some(Gid::from_raw(gid)))
        .map_err(|error| io_error(format!("set ownership {}: {error}", path.display())))?;
    file.set_permissions(Permissions::from_mode(mode))
        .map_err(|error| io_error(format!("set permissions {}: {error}", path.display())))?;
    file.sync_all()
        .map_err(|error| io_error(format!("sync regular file {}: {error}", path.display())))
}

fn trusted_owner() -> (u32, u32) {
    (Uid::effective().as_raw(), Gid::effective().as_raw())
}

fn create_parent<'a>(path: &'a Path, label: &str) -> Result<&'a Path, CliError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)
        .map_err(|error| io_error(format!("create directory {}: {error}", parent.display())))?;
    validate_trusted_ancestors(path, label)?;
    Ok(parent)
}

fn validate_trusted_ancestors(path: &Path, label: &str) -> Result<(), CliError> {
    let expected_uid = Uid::effective().as_raw();
    for ancestor in path.parent().into_iter().flat_map(Path::ancestors) {
        let metadata = match fs::symlink_metadata(ancestor) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(io_error(format!(
                    "inspect {label} ancestor {}: {error}",
                    ancestor.display()
                )));
            }
        };
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io_error(format!(
                "{label} ancestor is not a regular directory: {}",
                ancestor.display()
            )));
        }
        let root_owned = metadata.uid() == 0;
        if !root_owned && metadata.uid() != expected_uid {
            return Err(io_error(format!(
                "{label} ancestor {} has untrusted owner {}",
                ancestor.display(),
                metadata.uid()
            )));
        }
        if is_test_temp_boundary(ancestor, &metadata, expected_uid) {
            break;
        }
        let writable = metadata.mode() & 0o022 != 0;
        let trusted_sticky_root = root_owned && metadata.mode() & 0o1000 != 0;
        if writable && !trusted_sticky_root {
            return Err(io_error(format!(
                "{label} ancestor {} is group- or world-writable (mode {:04o})",
                ancestor.display(),
                metadata.mode() & 0o7777
            )));
        }
    }
    Ok(())
}

fn is_test_temp_boundary(path: &Path, metadata: &Metadata, expected_uid: u32) -> bool {
    cfg!(test)
        && path == temp_dir()
        && metadata.uid() == expected_uid
        && metadata.mode() & 0o022 == 0
}

fn prepare_temporary(
    parent: &Path,
    path: &Path,
    contents: &str,
    mode: u32,
) -> Result<NamedTempFile, CliError> {
    let mut temporary = NamedTempFile::new_in(parent)
        .map_err(|error| io_error(format!("create temp file for {}: {error}", path.display())))?;
    temporary
        .write_all(contents.as_bytes())
        .map_err(|error| io_error(format!("write temp file for {}: {error}", path.display())))?;
    temporary
        .flush()
        .map_err(|error| io_error(format!("flush temp file for {}: {error}", path.display())))?;
    apply_trusted_metadata(temporary.as_file(), path, mode)?;
    Ok(temporary)
}

fn sync_parent(path: &Path) -> Result<(), CliError> {
    path.parent().map_or(Ok(()), sync_directory)
}

fn sync_directory(path: &Path) -> Result<(), CliError> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| io_error(format!("sync directory {}: {error}", path.display())))
}

fn persist_error(path: &Path, error: &Error) -> CliError {
    io_error(format!("persist {}: {error}", path.display()))
}

fn io_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(message.into()).into()
}
