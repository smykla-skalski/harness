use std::ffi::OsStr;
use std::fs::Metadata;
use std::io::ErrorKind;
use std::io::Read as _;
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use fs_err as fs;
use sha2::{Digest as _, Sha256};
use uuid::Uuid;
use walkdir::WalkDir;

use crate::errors::CliError;

use super::files::{
    apply_path_metadata, combine_errors, copy_file_atomic, io_error, metadata_to_file_metadata,
    open_regular_nofollow, remove_tree_if_exists, sync_directory, sync_parent,
};
use super::model::FileMetadata;

pub(super) fn validate_state_tree(source: &Path) -> Result<(), CliError> {
    if !state_directory_exists(source)? {
        return Ok(());
    }
    for entry in WalkDir::new(source).follow_links(false).sort_by_file_name() {
        let entry = entry.map_err(|error| io_error(format!("walk systemd state: {error}")))?;
        validate_state_entry(entry.path())?;
    }
    Ok(())
}

pub(super) fn state_tree_sha256(source: &Path) -> Result<Option<String>, CliError> {
    if !state_directory_exists(source)? {
        return Ok(None);
    }
    let mut digest = Sha256::new();
    for entry in WalkDir::new(source).follow_links(false).sort_by_file_name() {
        let entry = entry.map_err(|error| io_error(format!("walk systemd state: {error}")))?;
        let path = entry.path();
        let metadata = validate_state_entry(path)?;
        let relative = path
            .strip_prefix(source)
            .map_err(|error| io_error(format!("resolve systemd state digest path: {error}")))?;
        let relative = relative.as_os_str().as_bytes();
        digest.update(
            u64::try_from(relative.len())
                .unwrap_or(u64::MAX)
                .to_le_bytes(),
        );
        digest.update(relative);
        digest.update(metadata.mode().to_le_bytes());
        digest.update(metadata.uid().to_le_bytes());
        digest.update(metadata.gid().to_le_bytes());
        if metadata.is_dir() {
            digest.update(b"d");
        } else {
            digest.update(b"f");
            digest.update(metadata.len().to_le_bytes());
            hash_file_contents(path, &mut digest)?;
        }
    }
    Ok(Some(hex::encode(digest.finalize())))
}

fn validate_state_entry(path: &Path) -> Result<Metadata, CliError> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| io_error(format!("inspect systemd state {}: {error}", path.display())))?;
    if metadata.file_type().is_symlink() {
        Err(io_error(format!(
            "refusing symbolic link in systemd state: {}",
            path.display()
        )))
    } else if metadata.is_dir() || metadata.is_file() {
        Ok(metadata)
    } else {
        Err(io_error(format!(
            "unsupported special file in systemd state: {}",
            path.display()
        )))
    }
}

fn hash_file_contents(path: &Path, digest: &mut Sha256) -> Result<(), CliError> {
    let mut file = open_regular_nofollow(path)?;
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| io_error(format!("hash state file {}: {error}", path.display())))?;
        digest.update(u64::try_from(read).unwrap_or(u64::MAX).to_le_bytes());
        if read == 0 {
            return Ok(());
        }
        digest.update(&buffer[..read]);
    }
}

pub(super) fn snapshot_state_tree(source: &Path, destination: &Path) -> Result<bool, CliError> {
    if !state_directory_exists(source)? {
        return Ok(false);
    }
    copy_tree_preserving(source, destination, true)?;
    Ok(true)
}

pub(super) fn restore_state_tree(
    source: &Path,
    destination: &Path,
    was_present: bool,
) -> Result<(), CliError> {
    restore_state_tree_internal(source, destination, was_present, None)
}

pub(super) fn restore_state_tree_retaining_current(
    source: &Path,
    destination: &Path,
    was_present: bool,
    retention_path: &Path,
) -> Result<(), CliError> {
    restore_state_tree_internal(source, destination, was_present, Some(retention_path))
}

fn restore_state_tree_internal(
    source: &Path,
    destination: &Path,
    was_present: bool,
    retention_path: Option<&Path>,
) -> Result<(), CliError> {
    let paths = prepare_state_restore(destination, retention_path)?;
    stage_restored_state(source, &paths.staging, was_present)?;
    displace_current_state(destination, &paths)?;
    install_restored_state(destination, was_present, &paths)?;
    finish_state_restore(&paths)
}

struct StateRestorePaths {
    parent: PathBuf,
    staging: PathBuf,
    displaced: PathBuf,
    destination_exists: bool,
    retain_displaced: bool,
}

fn prepare_state_restore(
    destination: &Path,
    retention_path: Option<&Path>,
) -> Result<StateRestorePaths, CliError> {
    let parent = destination.parent().ok_or_else(|| {
        io_error(format!(
            "state path has no parent: {}",
            destination.display()
        ))
    })?;
    fs::create_dir_all(parent).map_err(|error| {
        io_error(format!(
            "create systemd state parent {}: {error}",
            parent.display()
        ))
    })?;
    let nonce = Uuid::new_v4().simple().to_string();
    let staging = parent.join(format!(".harness-restore-{nonce}"));
    let temporary_displaced = parent.join(format!(".harness-displaced-{nonce}"));
    let destination_exists = path_entry_exists(destination)?;
    let retention_exists = retention_path
        .map(state_directory_exists)
        .transpose()?
        .unwrap_or(false);
    if let Some(retained) = retention_path.filter(|_| retention_exists) {
        normalize_retained_state(retained)?;
    }
    let (displaced, retain_displaced) =
        displacement_path(retention_path, retention_exists, temporary_displaced);
    Ok(StateRestorePaths {
        parent: parent.to_path_buf(),
        staging,
        displaced,
        destination_exists,
        retain_displaced,
    })
}

fn stage_restored_state(source: &Path, staging: &Path, was_present: bool) -> Result<(), CliError> {
    if !was_present {
        return Ok(());
    }
    if let Err(error) = copy_tree_preserving(source, staging, false) {
        let cleanup = remove_tree_if_exists(staging);
        return Err(combine_errors(
            "stage systemd state restore",
            &error,
            cleanup.err(),
        ));
    }
    Ok(())
}

fn displace_current_state(destination: &Path, paths: &StateRestorePaths) -> Result<(), CliError> {
    if !paths.destination_exists {
        return Ok(());
    }
    fs::rename(destination, &paths.displaced).map_err(|error| {
        io_error(format!(
            "displace systemd state {}: {error}",
            destination.display()
        ))
    })?;
    if paths.retain_displaced {
        normalize_retained_state(&paths.displaced)?;
    }
    sync_rename_parents(&paths.parent, &paths.displaced)
}

fn install_restored_state(
    destination: &Path,
    was_present: bool,
    paths: &StateRestorePaths,
) -> Result<(), CliError> {
    if !was_present {
        return Ok(());
    }
    if let Err(error) = fs::rename(&paths.staging, destination) {
        if paths.destination_exists && !paths.retain_displaced {
            let _ = fs::rename(&paths.displaced, destination);
        }
        Err(io_error(format!(
            "restore systemd state {}: {error}",
            destination.display()
        )))
    } else {
        Ok(())
    }
}

fn finish_state_restore(paths: &StateRestorePaths) -> Result<(), CliError> {
    sync_directory(&paths.parent)?;
    if paths.destination_exists && !paths.retain_displaced {
        remove_path_entry_if_exists(&paths.displaced)?;
        sync_directory(&paths.parent)?;
    }
    Ok(())
}

fn normalize_retained_state(path: &Path) -> Result<(), CliError> {
    apply_path_metadata(path, FileMetadata::private_executable())?;
    sync_directory(path)?;
    sync_parent(path)
}

fn path_entry_exists(path: &Path) -> Result<bool, CliError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error(format!(
            "inspect systemd state entry {}: {error}",
            path.display()
        ))),
    }
}

fn remove_path_entry_if_exists(path: &Path) -> Result<(), CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
            fs::remove_dir_all(path).map_err(|error| {
                io_error(format!(
                    "remove displaced state directory {}: {error}",
                    path.display()
                ))
            })
        }
        Ok(_) => fs::remove_file(path).map_err(|error| {
            io_error(format!(
                "remove displaced state entry {}: {error}",
                path.display()
            ))
        }),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(format!(
            "inspect displaced state entry {}: {error}",
            path.display()
        ))),
    }
}

fn displacement_path(
    retention_path: Option<&Path>,
    retention_exists: bool,
    temporary_displaced: PathBuf,
) -> (PathBuf, bool) {
    retention_path.filter(|_| !retention_exists).map_or_else(
        || (temporary_displaced, false),
        |retention| (retention.to_path_buf(), true),
    )
}

fn sync_rename_parents(state_parent: &Path, displaced: &Path) -> Result<(), CliError> {
    sync_directory(state_parent)?;
    let displaced_parent = displaced
        .parent()
        .ok_or_else(|| io_error("retained systemd state path has no parent"))?;
    if displaced_parent != state_parent {
        sync_directory(displaced_parent)?;
    }
    Ok(())
}

fn state_directory_exists(path: &Path) -> Result<bool, CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err(io_error(format!(
                "systemd state path is not a regular directory: {}",
                path.display()
            )))
        }
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error(format!(
            "inspect systemd state directory {}: {error}",
            path.display()
        ))),
    }
}

fn copy_tree_preserving(
    source: &Path,
    destination: &Path,
    skip_database_sidecars: bool,
) -> Result<(), CliError> {
    if !state_directory_exists(source)? {
        return Err(io_error(format!(
            "systemd state directory is missing: {}",
            source.display()
        )));
    }
    if destination.exists() {
        return Err(io_error(format!(
            "snapshot destination already exists: {}",
            destination.display()
        )));
    }
    let mut directories = Vec::new();
    for entry in WalkDir::new(source).follow_links(false).sort_by_file_name() {
        let entry = entry.map_err(|error| io_error(format!("walk systemd state: {error}")))?;
        let path = entry.path();
        if skip_database_sidecars && is_database_sidecar(source, path) {
            continue;
        }
        let relative = path
            .strip_prefix(source)
            .map_err(|error| io_error(format!("resolve systemd state snapshot path: {error}")))?;
        let target = destination.join(relative);
        let metadata = fs::symlink_metadata(path).map_err(|error| {
            io_error(format!("inspect systemd state {}: {error}", path.display()))
        })?;
        if metadata.file_type().is_symlink() {
            return Err(io_error(format!(
                "refusing symbolic link in systemd state: {}",
                path.display()
            )));
        }
        if metadata.is_dir() {
            fs::create_dir(&target).map_err(|error| {
                io_error(format!(
                    "create state snapshot {}: {error}",
                    target.display()
                ))
            })?;
            directories.push((target, metadata_to_file_metadata(&metadata)));
        } else if metadata.is_file() {
            copy_file_atomic(path, &target, metadata_to_file_metadata(&metadata))?;
        } else {
            return Err(io_error(format!(
                "unsupported special file in systemd state: {}",
                path.display()
            )));
        }
    }
    for (path, metadata) in directories.into_iter().rev() {
        apply_path_metadata(&path, metadata)?;
        sync_directory(&path)?;
    }
    sync_parent(destination)
}

fn is_database_sidecar(state_root: &Path, path: &Path) -> bool {
    let database_parent = state_root.join("daemon").join("external");
    path.parent() == Some(database_parent.as_path())
        && matches!(
            path.file_name().and_then(OsStr::to_str),
            Some("harness.db-wal" | "harness.db-shm" | "harness.db-journal")
        )
}

#[cfg(test)]
pub(crate) fn restore_state_tree_for_tests(
    source: &Path,
    destination: &Path,
    was_present: bool,
) -> Result<(), CliError> {
    restore_state_tree(source, destination, was_present)
}

#[cfg(test)]
pub(crate) fn restore_state_tree_retaining_current_for_tests(
    source: &Path,
    destination: &Path,
    was_present: bool,
    retention_path: &Path,
) -> Result<(), CliError> {
    restore_state_tree_retaining_current(source, destination, was_present, retention_path)
}

#[cfg(test)]
pub(crate) fn snapshot_state_tree_for_tests(
    source: &Path,
    destination: &Path,
) -> Result<bool, CliError> {
    snapshot_state_tree(source, destination)
}
