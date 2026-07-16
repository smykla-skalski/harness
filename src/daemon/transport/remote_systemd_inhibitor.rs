use std::fs::{DirBuilder, File, Metadata, OpenOptions, Permissions};
use std::io::{ErrorKind, Read as _, Write as _};
use std::os::unix::fs::{
    DirBuilderExt as _, MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _,
};
use std::path::{Component, Path, PathBuf};

use fs_err as fs;
use nix::unistd::{Gid, Uid, fchown};
use tempfile::NamedTempFile;

use crate::errors::{CliError, CliErrorKind};

const INHIBITOR_FILE_NAME: &str = "90-harness-inhibit.conf";
const INHIBITOR_BYTES: &[u8] = b"[Unit]\nConditionPathExists=!/\n";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DirectoryState {
    Absent,
    Present,
}

pub(crate) fn inhibitor_path(unit_path: &Path) -> Result<PathBuf, CliError> {
    validate_absolute_normalized(unit_path)?;
    let service = unit_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| io_error("systemd unit path requires a UTF-8 service filename"))?;
    let Some(stem) = service.strip_suffix(".service") else {
        return Err(io_error(format!(
            "systemd unit path must end in .service: {}",
            unit_path.display()
        )));
    };
    if stem.is_empty() {
        return Err(io_error(format!(
            "systemd unit path has an empty service name: {}",
            unit_path.display()
        )));
    }
    let parent = unit_path.parent().ok_or_else(|| {
        io_error(format!(
            "systemd unit path has no parent: {}",
            unit_path.display()
        ))
    })?;
    Ok(parent
        .join(format!("{service}.d"))
        .join(INHIBITOR_FILE_NAME))
}

pub(crate) fn inhibitor_is_installed(unit_path: &Path) -> Result<bool, CliError> {
    let path = inhibitor_path(unit_path)?;
    validate_unit_directory(unit_path)?;
    let drop_in_directory = path
        .parent()
        .ok_or_else(|| io_error(format!("inhibitor path has no parent: {}", path.display())))?;
    if inspect_managed_directory(drop_in_directory)? == DirectoryState::Absent {
        return Ok(false);
    }
    Ok(open_exact_inhibitor(&path)?.is_some())
}

pub(crate) fn install_inhibitor(unit_path: &Path) -> Result<PathBuf, CliError> {
    let path = inhibitor_path(unit_path)?;
    let unit_directory = validate_unit_directory(unit_path)?;
    let drop_in_directory = path
        .parent()
        .ok_or_else(|| io_error(format!("inhibitor path has no parent: {}", path.display())))?;
    ensure_managed_directory(drop_in_directory, unit_directory)?;
    install_exact_file(&path, drop_in_directory)?;
    Ok(path)
}

pub(crate) fn remove_inhibitor(unit_path: &Path) -> Result<bool, CliError> {
    let path = inhibitor_path(unit_path)?;
    let unit_directory = validate_unit_directory(unit_path)?;
    let drop_in_directory = path
        .parent()
        .ok_or_else(|| io_error(format!("inhibitor path has no parent: {}", path.display())))?;
    if inspect_managed_directory(drop_in_directory)? == DirectoryState::Absent {
        return Ok(false);
    }
    let Some(file) = open_exact_inhibitor(&path)? else {
        remove_empty_managed_directory(drop_in_directory, unit_directory)?;
        return Ok(false);
    };
    require_same_open_file(&file, &path)?;
    fs::remove_file(&path).map_err(|error| {
        io_error(format!(
            "remove systemd inhibitor {}: {error}",
            path.display()
        ))
    })?;
    sync_directory(drop_in_directory)?;
    remove_empty_managed_directory(drop_in_directory, unit_directory)?;
    Ok(true)
}

fn validate_absolute_normalized(path: &Path) -> Result<(), CliError> {
    if path.is_absolute()
        && !path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "systemd unit path must be absolute and normalized: {}",
            path.display()
        )))
    }
}

fn validate_unit_directory(unit_path: &Path) -> Result<&Path, CliError> {
    let parent = unit_path.parent().ok_or_else(|| {
        io_error(format!(
            "systemd unit path has no parent: {}",
            unit_path.display()
        ))
    })?;
    for ancestor in parent.ancestors() {
        validate_trusted_ancestor(ancestor)?;
    }
    Ok(parent)
}

fn validate_trusted_ancestor(path: &Path) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        io_error(format!(
            "inspect systemd unit directory ancestor {}: {error}",
            path.display()
        ))
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io_error(format!(
            "systemd unit directory ancestor is not a real directory: {}",
            path.display()
        )));
    }
    if metadata.uid() != 0 && metadata.uid() != trusted_uid() {
        return Err(io_error(format!(
            "systemd unit directory ancestor has untrusted owner {}: {}",
            metadata.uid(),
            path.display()
        )));
    }
    let trusted_sticky_root = metadata.uid() == 0 && metadata.mode() & 0o1000 != 0;
    if metadata.mode() & 0o022 != 0 && !trusted_sticky_root {
        return Err(io_error(format!(
            "systemd unit directory ancestor is group- or world-writable: {}",
            path.display()
        )));
    }
    Ok(())
}

fn inspect_managed_directory(path: &Path) -> Result<DirectoryState, CliError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(DirectoryState::Absent),
        Err(error) => {
            return Err(io_error(format!(
                "inspect systemd inhibitor directory {}: {error}",
                path.display()
            )));
        }
    };
    validate_managed_directory_metadata(path, &metadata)?;
    Ok(DirectoryState::Present)
}

fn validate_managed_directory_metadata(path: &Path, metadata: &Metadata) -> Result<(), CliError> {
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io_error(format!(
            "systemd inhibitor directory is not a real directory: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() || metadata.gid() != trusted_gid() {
        return Err(io_error(format!(
            "systemd inhibitor directory has untrusted owner {}:{}: {}",
            metadata.uid(),
            metadata.gid(),
            path.display()
        )));
    }
    if metadata.mode() & 0o7777 != 0o755 {
        return Err(io_error(format!(
            "systemd inhibitor directory must have mode 0755, found {:04o}: {}",
            metadata.mode() & 0o7777,
            path.display(),
        )));
    }
    Ok(())
}

fn ensure_managed_directory(path: &Path, unit_directory: &Path) -> Result<(), CliError> {
    if inspect_managed_directory(path)? == DirectoryState::Present {
        sync_directory(path)?;
        return Ok(());
    }
    let mut builder = DirBuilder::new();
    builder.mode(0o755);
    match builder.create(path) {
        Ok(()) => {
            secure_created_directory(path)?;
            sync_directory(unit_directory)
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            if inspect_managed_directory(path)? != DirectoryState::Present {
                return Err(io_error(format!(
                    "systemd inhibitor directory disappeared during creation: {}",
                    path.display()
                )));
            }
            sync_directory(path)
        }
        Err(error) => Err(io_error(format!(
            "create systemd inhibitor directory {}: {error}",
            path.display()
        ))),
    }
}

fn secure_created_directory(path: &Path) -> Result<(), CliError> {
    let directory = open_directory_nofollow(path)?;
    let (uid, gid) = trusted_owner();
    fchown(
        &directory,
        Some(Uid::from_raw(uid)),
        Some(Gid::from_raw(gid)),
    )
    .map_err(|error| {
        io_error(format!(
            "set systemd inhibitor directory ownership {}: {error}",
            path.display()
        ))
    })?;
    directory
        .set_permissions(Permissions::from_mode(0o755))
        .map_err(|error| {
            io_error(format!(
                "set systemd inhibitor directory permissions {}: {error}",
                path.display()
            ))
        })?;
    directory.sync_all().map_err(|error| {
        io_error(format!(
            "sync systemd inhibitor directory {}: {error}",
            path.display()
        ))
    })?;
    let metadata = directory.metadata().map_err(|error| {
        io_error(format!(
            "inspect created systemd inhibitor directory {}: {error}",
            path.display()
        ))
    })?;
    validate_managed_directory_metadata(path, &metadata)
}

fn install_exact_file(path: &Path, parent: &Path) -> Result<(), CliError> {
    if let Some(file) = open_exact_inhibitor(path)? {
        sync_open_file(&file, path)?;
        return sync_directory(parent);
    }
    let mut temporary = NamedTempFile::new_in(parent).map_err(|error| {
        io_error(format!(
            "create temporary systemd inhibitor for {}: {error}",
            path.display()
        ))
    })?;
    temporary.write_all(INHIBITOR_BYTES).map_err(|error| {
        io_error(format!(
            "write temporary systemd inhibitor for {}: {error}",
            path.display()
        ))
    })?;
    temporary.flush().map_err(|error| {
        io_error(format!(
            "flush temporary systemd inhibitor for {}: {error}",
            path.display()
        ))
    })?;
    secure_created_file(temporary.as_file(), path)?;
    match temporary.persist_noclobber(path) {
        Ok(_) => sync_directory(parent),
        Err(error) if error.error.kind() == ErrorKind::AlreadyExists => {
            drop(error);
            let file = open_exact_inhibitor(path)?.ok_or_else(|| {
                io_error(format!(
                    "systemd inhibitor disappeared during installation: {}",
                    path.display()
                ))
            })?;
            sync_open_file(&file, path)?;
            sync_directory(parent)
        }
        Err(error) => Err(io_error(format!(
            "persist systemd inhibitor {}: {}",
            path.display(),
            error.error
        ))),
    }
}

fn secure_created_file(file: &File, path: &Path) -> Result<(), CliError> {
    let (uid, gid) = trusted_owner();
    fchown(file, Some(Uid::from_raw(uid)), Some(Gid::from_raw(gid))).map_err(|error| {
        io_error(format!(
            "set systemd inhibitor ownership {}: {error}",
            path.display()
        ))
    })?;
    file.set_permissions(Permissions::from_mode(0o644))
        .map_err(|error| {
            io_error(format!(
                "set systemd inhibitor permissions {}: {error}",
                path.display()
            ))
        })?;
    sync_open_file(file, path)
}

fn open_exact_inhibitor(path: &Path) -> Result<Option<File>, CliError> {
    let initial = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(io_error(format!(
                "inspect systemd inhibitor {}: {error}",
                path.display()
            )));
        }
    };
    validate_inhibitor_metadata(path, &initial)?;
    let mut file = open_regular_nofollow(path)?;
    let opened = file.metadata().map_err(|error| {
        io_error(format!(
            "inspect open systemd inhibitor {}: {error}",
            path.display()
        ))
    })?;
    validate_inhibitor_metadata(path, &opened)?;
    if initial.dev() != opened.dev() || initial.ino() != opened.ino() {
        return Err(io_error(format!(
            "systemd inhibitor changed while opening: {}",
            path.display()
        )));
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|error| {
        io_error(format!(
            "read systemd inhibitor {}: {error}",
            path.display()
        ))
    })?;
    if bytes != INHIBITOR_BYTES {
        return Err(io_error(format!(
            "refusing unrelated systemd inhibitor file {}",
            path.display()
        )));
    }
    Ok(Some(file))
}

fn validate_inhibitor_metadata(path: &Path, metadata: &Metadata) -> Result<(), CliError> {
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(io_error(format!(
            "systemd inhibitor is not a regular file: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() || metadata.gid() != trusted_gid() {
        return Err(io_error(format!(
            "systemd inhibitor has untrusted owner {}:{}: {}",
            metadata.uid(),
            metadata.gid(),
            path.display()
        )));
    }
    if metadata.mode() & 0o7777 != 0o644 {
        return Err(io_error(format!(
            "systemd inhibitor must have mode 0644, found {:04o}: {}",
            metadata.mode() & 0o7777,
            path.display(),
        )));
    }
    if metadata.nlink() != 1 {
        return Err(io_error(format!(
            "systemd inhibitor must have exactly one hard link, found {}: {}",
            metadata.nlink(),
            path.display(),
        )));
    }
    Ok(())
}

fn open_regular_nofollow(path: &Path) -> Result<File, CliError> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| {
            io_error(format!(
                "open systemd inhibitor {}: {error}",
                path.display()
            ))
        })
}

fn open_directory_nofollow(path: &Path) -> Result<File, CliError> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| {
            io_error(format!(
                "open systemd inhibitor directory {}: {error}",
                path.display()
            ))
        })
}

fn require_same_open_file(file: &File, path: &Path) -> Result<(), CliError> {
    let opened = file.metadata().map_err(|error| {
        io_error(format!(
            "inspect open systemd inhibitor before removal {}: {error}",
            path.display()
        ))
    })?;
    let current = fs::symlink_metadata(path).map_err(|error| {
        io_error(format!(
            "inspect systemd inhibitor before removal {}: {error}",
            path.display()
        ))
    })?;
    validate_inhibitor_metadata(path, &current)?;
    if opened.dev() == current.dev() && opened.ino() == current.ino() {
        Ok(())
    } else {
        Err(io_error(format!(
            "systemd inhibitor changed before removal: {}",
            path.display()
        )))
    }
}

fn remove_empty_managed_directory(path: &Path, unit_directory: &Path) -> Result<(), CliError> {
    if inspect_managed_directory(path)? == DirectoryState::Absent {
        return sync_directory(unit_directory);
    }
    match fs::remove_dir(path) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) if error.kind() == ErrorKind::DirectoryNotEmpty => return Ok(()),
        Err(error) => {
            return Err(io_error(format!(
                "remove empty systemd inhibitor directory {}: {error}",
                path.display()
            )));
        }
    }
    sync_directory(unit_directory)
}

fn sync_open_file(file: &File, path: &Path) -> Result<(), CliError> {
    file.sync_all().map_err(|error| {
        io_error(format!(
            "sync systemd inhibitor {}: {error}",
            path.display()
        ))
    })
}

fn sync_directory(path: &Path) -> Result<(), CliError> {
    open_directory_nofollow(path)?.sync_all().map_err(|error| {
        io_error(format!(
            "sync systemd inhibitor directory {}: {error}",
            path.display()
        ))
    })
}

fn trusted_owner() -> (u32, u32) {
    (trusted_uid(), trusted_gid())
}

#[cfg(not(test))]
const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_uid() -> u32 {
    Uid::effective().as_raw()
}

#[cfg(not(test))]
const fn trusted_gid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_gid() -> u32 {
    Gid::effective().as_raw()
}

fn io_error(detail: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(detail.into()).into()
}

#[cfg(test)]
#[path = "remote_systemd_inhibitor/tests.rs"]
mod tests;
