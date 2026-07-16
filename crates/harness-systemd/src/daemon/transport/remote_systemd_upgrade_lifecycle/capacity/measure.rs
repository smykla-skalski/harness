use std::io::ErrorKind;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use fs_err as fs;
use walkdir::WalkDir;

use crate::errors::CliError;

use super::super::files::io_error;

#[derive(Debug, Default, Clone, Copy)]
pub(super) struct TreeCapacity {
    pub(super) bytes: u64,
    pub(super) inodes: u64,
}

impl TreeCapacity {
    pub(super) fn checked_add(self, other: Self, label: &str) -> Result<Self, CliError> {
        Ok(Self {
            bytes: checked_capacity_sum(self.bytes, other.bytes, label)?,
            inodes: checked_inode_sum(self.inodes, other.inodes, label)?,
        })
    }

    pub(super) fn with_headroom(
        self,
        bytes: u64,
        inodes: u64,
        label: &str,
    ) -> Result<Self, CliError> {
        self.checked_add(Self { bytes, inodes }, label)
    }
}

pub(super) fn tree_copy_capacity(path: &Path) -> Result<TreeCapacity, CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(io_error(format!(
                "restore capacity source is not a regular directory: {}",
                path.display()
            )));
        }
        Ok(_) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(TreeCapacity::default()),
        Err(error) => {
            return Err(io_error(format!(
                "inspect restore capacity source {}: {error}",
                path.display()
            )));
        }
    }
    let mut capacity = TreeCapacity::default();
    for entry in WalkDir::new(path).follow_links(false) {
        let entry = entry.map_err(|error| io_error(format!("size restore state: {error}")))?;
        let metadata = fs::symlink_metadata(entry.path()).map_err(|error| {
            io_error(format!(
                "inspect restore capacity entry {}: {error}",
                entry.path().display()
            ))
        })?;
        if metadata.file_type().is_symlink() {
            return Err(io_error(format!(
                "refusing symbolic link in restore capacity source: {}",
                entry.path().display()
            )));
        }
        if metadata.is_dir() {
            capacity.inodes = checked_inode_sum(capacity.inodes, 1, "state restore")?;
        } else if metadata.is_file() && !is_database_sidecar(path, entry.path()) {
            capacity.bytes = checked_capacity_sum(
                capacity.bytes,
                metadata.len().max(metadata.blocks().saturating_mul(512)),
                "state restore",
            )?;
            capacity.inodes = checked_inode_sum(capacity.inodes, 1, "state restore")?;
        } else if !metadata.is_file() {
            return Err(io_error(format!(
                "unsupported restore capacity source entry: {}",
                entry.path().display()
            )));
        }
    }
    Ok(capacity)
}

fn checked_inode_sum(total: u64, inodes: u64, label: &str) -> Result<u64, CliError> {
    total
        .checked_add(inodes)
        .ok_or_else(|| io_error(format!("{label} inode capacity exceeds the supported size")))
}

fn checked_capacity_sum(total: u64, bytes: u64, label: &str) -> Result<u64, CliError> {
    total
        .checked_add(bytes)
        .ok_or_else(|| io_error(format!("{label} capacity exceeds the supported size")))
}

fn is_database_sidecar(state_root: &Path, path: &Path) -> bool {
    let database_parent = state_root.join("daemon").join("external");
    path.parent() == Some(database_parent.as_path())
        && matches!(
            path.file_name().and_then(|name| name.to_str()),
            Some("harness.db-wal" | "harness.db-shm" | "harness.db-journal")
        )
}
