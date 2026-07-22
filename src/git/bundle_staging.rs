use std::fs::{self, File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};

use fs2::FileExt as _;
use tempfile::{NamedTempFile, TempDir};

use super::repository_coordinates::GitRepositoryCoordinates;
use crate::git::{GitError, GitResult};

const STAGING_DIRECTORY: &str = "harness-task-board-bundle-staging";
const STAGING_LOCK: &str = "harness-task-board-bundle-staging.lock";

pub(super) struct GitBundleStaging<'a> {
    coordinates: &'a GitRepositoryCoordinates,
    staged: NamedTempFile,
    _directory: TempDir,
    _lock: File,
}

impl<'a> GitBundleStaging<'a> {
    pub(super) fn prepare(
        coordinates: &'a GitRepositoryCoordinates,
        bytes: &[u8],
        max_bytes: u64,
    ) -> GitResult<Self> {
        coordinates.require_current()?;
        require_bounded_bytes(coordinates.worktree(), bytes, max_bytes)?;
        let lock = acquire_lock(coordinates)?;
        coordinates.require_current()?;
        let root = staging_root(coordinates);
        reset_staging(coordinates.worktree(), &root)?;
        let directory = TempDir::new_in(&root)
            .map_err(|error| GitError::unsafe_state(coordinates.worktree(), error))?;
        let mut staged = NamedTempFile::new_in(directory.path())
            .map_err(|error| GitError::unsafe_state(coordinates.worktree(), error))?;
        staged
            .write_all(bytes)
            .and_then(|()| staged.flush())
            .map_err(|error| GitError::unsafe_state(coordinates.worktree(), error))?;
        coordinates.require_current()?;
        Ok(Self {
            coordinates,
            staged,
            _directory: directory,
            _lock: lock,
        })
    }

    pub(super) fn path(&self) -> GitResult<&str> {
        self.coordinates.require_current()?;
        self.staged.path().to_str().ok_or_else(|| {
            GitError::unsafe_state(
                self.coordinates.worktree(),
                "staged bundle path is not UTF-8",
            )
        })
    }
}

fn acquire_lock(coordinates: &GitRepositoryCoordinates) -> GitResult<File> {
    let path = coordinates.common_git_dir().join(STAGING_LOCK);
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)
        .map_err(|error| GitError::read(coordinates.worktree(), error))?;
    lock.lock_exclusive()
        .map_err(|error| GitError::read(coordinates.worktree(), error))?;
    Ok(lock)
}

fn require_bounded_bytes(worktree: &Path, bytes: &[u8], max_bytes: u64) -> GitResult<()> {
    let size = u64::try_from(bytes.len())
        .map_err(|_| GitError::unsafe_state(worktree, "Git bundle length overflowed"))?;
    if max_bytes == 0 || size > max_bytes {
        Err(GitError::unsafe_state(
            worktree,
            "Git bundle exceeds its staging byte contract",
        ))
    } else {
        Ok(())
    }
}

fn reset_staging(worktree: &Path, root: &Path) -> GitResult<()> {
    remove_staging(root).map_err(|error| GitError::read(worktree, error))?;
    fs::create_dir_all(root).map_err(|error| GitError::read(worktree, error))
}

fn remove_staging(root: &Path) -> std::io::Result<()> {
    let Ok(metadata) = fs::symlink_metadata(root) else {
        return Ok(());
    };
    if metadata.file_type().is_symlink() || metadata.is_file() {
        fs::remove_file(root)
    } else {
        fs::remove_dir_all(root)
    }
}

fn staging_root(coordinates: &GitRepositoryCoordinates) -> PathBuf {
    coordinates.common_git_dir().join(STAGING_DIRECTORY)
}

#[cfg(test)]
pub(super) fn staging_root_for_test(coordinates: &GitRepositoryCoordinates) -> PathBuf {
    staging_root(coordinates)
}
