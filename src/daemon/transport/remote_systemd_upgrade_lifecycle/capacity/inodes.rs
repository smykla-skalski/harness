use std::fs::{DirBuilder, OpenOptions};
use std::io::ErrorKind;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::Path;

use fs_err as fs;
use nix::sys::statvfs::statvfs;

use crate::errors::CliError;

use super::super::files::{io_error, remove_tree_if_exists, sync_directory};

pub(super) fn reserve_inode_capacity(path: &Path, required: u64) -> Result<(), CliError> {
    let parent = path.parent().ok_or_else(|| {
        io_error(format!(
            "inode restore reserve has no parent: {}",
            path.display()
        ))
    })?;
    reserve_inode_capacity_with_available(path, required, available_inodes(parent)?)
}

fn reserve_inode_capacity_with_available(
    path: &Path,
    required: u64,
    available: Option<u64>,
) -> Result<(), CliError> {
    let total_required = required
        .checked_add(1)
        .ok_or_else(|| io_error("rollback inode capacity exceeds the supported size"))?;
    if available.is_some_and(|available| available < total_required) {
        return Err(io_error(format!(
            "insufficient rollback inode capacity for {}: need {total_required}, available {}",
            path.display(),
            available.unwrap_or_default()
        )));
    }
    DirBuilder::new()
        .mode(0o700)
        .create(path)
        .map_err(|error| {
            io_error(format!(
                "create rollback inode reserve {}: {error}",
                path.display()
            ))
        })?;
    if let Err(error) = create_inode_placeholders(path, required) {
        let cleanup = remove_tree_if_exists(path).and_then(|()| sync_directory_parent(path));
        return Err(super::combine_errors(
            "reserve rollback inode capacity",
            &error,
            cleanup.err(),
        ));
    }
    sync_directory(path)?;
    sync_directory_parent(path)
}

fn available_inodes(path: &Path) -> Result<Option<u64>, CliError> {
    let statistics = statvfs(path).map_err(|error| {
        io_error(format!(
            "inspect rollback inode capacity {}: {error}",
            path.display()
        ))
    })?;
    if statistics.files() == 0 {
        Ok(None)
    } else {
        Ok(Some(statistics.files_available()))
    }
}

fn create_inode_placeholders(path: &Path, required: u64) -> Result<(), CliError> {
    for index in 0..required {
        let placeholder = path.join(format!("{index:016x}"));
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&placeholder)
            .map_err(|error| {
                io_error(format!(
                    "create rollback inode placeholder {}: {error}",
                    placeholder.display()
                ))
            })?;
    }
    Ok(())
}

pub(super) fn inode_reserve_is_sufficient(path: &Path, required: u64) -> Result<bool, CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err(io_error(format!(
                "restore inode reserve is not a regular directory: {}",
                path.display()
            )))
        }
        Ok(_) => count_placeholders(path).map(|count| count >= required),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error(format!(
            "inspect restore inode reserve {}: {error}",
            path.display()
        ))),
    }
}

fn count_placeholders(path: &Path) -> Result<u64, CliError> {
    let mut count = 0_u64;
    for entry in fs::read_dir(path).map_err(|error| {
        io_error(format!(
            "read restore inode reserve {}: {error}",
            path.display()
        ))
    })? {
        let entry =
            entry.map_err(|error| io_error(format!("read inode reserve entry: {error}")))?;
        let metadata = fs::symlink_metadata(entry.path()).map_err(|error| {
            io_error(format!(
                "inspect inode reserve entry {}: {error}",
                entry.path().display()
            ))
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(io_error(format!(
                "restore inode reserve entry is not a regular file: {}",
                entry.path().display()
            )));
        }
        count = count
            .checked_add(1)
            .ok_or_else(|| io_error("rollback inode reserve entry count overflow"))?;
    }
    Ok(count)
}

pub(super) fn release_inode_capacity(path: &Path) -> Result<(), CliError> {
    remove_tree_if_exists(path)
}

fn sync_directory_parent(path: &Path) -> Result<(), CliError> {
    path.parent().map_or_else(
        || Err(io_error("inode restore reserve has no parent")),
        sync_directory,
    )
}

#[cfg(test)]
pub(crate) fn reserve_inode_capacity_with_available_for_tests(
    path: &Path,
    required: u64,
    available: u64,
) -> Result<(), CliError> {
    reserve_inode_capacity_with_available(path, required, Some(available))
}
