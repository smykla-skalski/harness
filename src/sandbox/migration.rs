//! One-shot migration from the legacy `~/Library/Application Support/harness`
//! data root to the new app-group-container root.

use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs as unix_fs;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use tracing::{info, warn};

#[must_use]
#[derive(Debug, PartialEq, Eq)]
pub enum MigrationOutcome {
    Migrated,
    AlreadyMigrated,
    SkippedOldAbsent,
    SplitAcknowledged,
    SplitAlreadyAcknowledged,
    ConcurrentlyMigrating,
}

#[derive(Debug, Error)]
pub enum MigrationError {
    #[error("I/O: {0}")]
    Io(#[from] io::Error),
    #[error("serde: {0}")]
    Serde(#[from] serde_json::Error),
}

const MARKER_NAME: &str = ".migrated-from";
const SPLIT_MARKER_NAME: &str = ".split-root-acknowledged";
const LOCK_NAME: &str = ".migration.lock";

#[derive(Debug, Serialize)]
struct Marker {
    from_path: PathBuf,
    migrated_at: String,
    harness_version: &'static str,
}

#[derive(Debug, Deserialize, Serialize)]
struct SplitMarker {
    from_path: PathBuf,
    acknowledged_at: String,
    old_root_digest: String,
    harness_version: String,
}

/// Migrate data from `old_root` to `new_root` if conditions permit.
///
/// # Errors
///
/// Returns `MigrationError::Io` on any filesystem failure, or
/// `MigrationError::Serde` if the marker file cannot be serialized.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn migrate(old_root: &Path, new_root: &Path) -> Result<MigrationOutcome, MigrationError> {
    if old_root == new_root {
        return Ok(MigrationOutcome::AlreadyMigrated);
    }
    let old_has_content = dir_has_content(old_root)?;
    let new_has_content = dir_has_content(new_root)?;
    if has_migration_marker(new_root) {
        if !old_has_content {
            return Ok(MigrationOutcome::AlreadyMigrated);
        }
        let message = if new_has_content {
            "data-root split: both old and new have content; new wins, leaving old in place"
        } else {
            "legacy data root gained content after migration; new wins, leaving old in place"
        };
        return acknowledge_split(old_root, new_root, message);
    }
    if !old_has_content {
        return Ok(MigrationOutcome::SkippedOldAbsent);
    }
    if new_has_content {
        return acknowledge_split(
            old_root,
            new_root,
            "data-root split: both old and new have content; new wins, leaving old in place",
        );
    }

    fs::create_dir_all(new_root)?;
    let Some(_lock) = acquire_lock(new_root)? else {
        // Another process is mid-migration; back off.
        return Ok(MigrationOutcome::ConcurrentlyMigrating);
    };
    move_contents(old_root, new_root)?;
    remove_split_marker(new_root)?;
    write_marker(new_root, old_root)?;
    info!(from = %old_root.display(), to = %new_root.display(), "migrated data root");
    Ok(MigrationOutcome::Migrated)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn acknowledge_split(
    old_root: &Path,
    new_root: &Path,
    message: &'static str,
) -> Result<MigrationOutcome, MigrationError> {
    let old_root_digest = dir_digest(old_root)?;
    if split_marker_matches(new_root, old_root, &old_root_digest)? {
        return Ok(MigrationOutcome::SplitAlreadyAcknowledged);
    }
    warn!(old = %old_root.display(), new = %new_root.display(), "{message}");
    write_split_marker(new_root, old_root, &old_root_digest)?;
    Ok(MigrationOutcome::SplitAcknowledged)
}

fn split_marker_matches(
    new_root: &Path,
    old_root: &Path,
    old_root_digest: &str,
) -> Result<bool, MigrationError> {
    Ok(load_split_marker(new_root)?.as_ref().is_some_and(|marker| {
        marker.from_path == old_root && marker.old_root_digest == old_root_digest
    }))
}

fn has_migration_marker(new_root: &Path) -> bool {
    new_root.join(MARKER_NAME).exists()
}

fn load_split_marker(new_root: &Path) -> Result<Option<SplitMarker>, MigrationError> {
    let marker_path = new_root.join(SPLIT_MARKER_NAME);
    if !marker_path.exists() {
        return Ok(None);
    }
    let bytes = fs::read(marker_path)?;
    Ok(Some(serde_json::from_slice(&bytes)?))
}

fn write_split_marker(
    new_root: &Path,
    old_root: &Path,
    old_root_digest: &str,
) -> Result<(), MigrationError> {
    let marker = SplitMarker {
        from_path: old_root.to_path_buf(),
        acknowledged_at: Utc::now().to_rfc3339(),
        old_root_digest: old_root_digest.to_string(),
        harness_version: env!("CARGO_PKG_VERSION").to_string(),
    };
    write_named_json_marker(new_root, SPLIT_MARKER_NAME, &marker)
}

fn remove_split_marker(new_root: &Path) -> io::Result<()> {
    let marker_path = new_root.join(SPLIT_MARKER_NAME);
    match fs::remove_file(marker_path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn dir_has_content(path: &Path) -> io::Result<bool> {
    if !path.exists() {
        return Ok(false);
    }
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        if is_internal_migration_entry_name(&entry.file_name().to_string_lossy()) {
            continue;
        }
        return Ok(true);
    }
    Ok(false)
}

fn dir_digest(path: &Path) -> io::Result<String> {
    let mut hasher = Sha256::new();
    hash_path(path, Path::new(""), &mut hasher)?;
    Ok(hex::encode(hasher.finalize()))
}

fn hash_path(path: &Path, relative_path: &Path, hasher: &mut Sha256) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    let file_type = metadata.file_type();
    if file_type.is_symlink() {
        hasher.update(b"symlink");
        hasher.update(relative_path.as_os_str().as_bytes());
        hasher.update(b"\0");
        let target = fs::read_link(path)?;
        hasher.update(target.as_os_str().as_bytes());
        hasher.update(b"\0");
        return Ok(());
    }
    if file_type.is_dir() {
        hasher.update(b"dir");
        hasher.update(relative_path.as_os_str().as_bytes());
        hasher.update(b"\0");
        let mut children = Vec::new();
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            if is_internal_migration_entry_name(&entry.file_name().to_string_lossy()) {
                continue;
            }
            children.push(entry);
        }
        children.sort_by_key(fs::DirEntry::file_name);
        for entry in children {
            let child_name = entry.file_name();
            let child_relative_path = if relative_path.as_os_str().is_empty() {
                PathBuf::from(&child_name)
            } else {
                relative_path.join(&child_name)
            };
            hash_path(&entry.path(), &child_relative_path, hasher)?;
        }
        return Ok(());
    }
    hasher.update(b"file");
    hasher.update(relative_path.as_os_str().as_bytes());
    hasher.update(b"\0");
    hasher.update(metadata.len().to_le_bytes());
    hasher.update(b"\0");
    hasher.update(fs::read(path)?);
    hasher.update(b"\0");
    Ok(())
}

fn is_internal_migration_entry_name(name: &str) -> bool {
    matches!(
        name,
        MARKER_NAME
            | SPLIT_MARKER_NAME
            | LOCK_NAME
            | ".migrated-from.tmp"
            | ".split-root-acknowledged.tmp"
    )
}

/// Advisory lock: `O_CREAT | O_EXCL` on a sibling file. Caller holds the
/// returned guard for the duration of the critical section; Drop removes
/// the lock file so a subsequent restart can proceed.
fn acquire_lock(new_root: &Path) -> io::Result<Option<LockGuard>> {
    let lock_path = new_root.join(LOCK_NAME);
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&lock_path)
    {
        Ok(_) => Ok(Some(LockGuard { path: lock_path })),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Ok(None),
        Err(e) => Err(e),
    }
}

struct LockGuard {
    path: PathBuf,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn write_named_json_marker<T: Serialize>(
    new_root: &Path,
    marker_name: &str,
    marker: &T,
) -> Result<(), MigrationError> {
    let bytes = serde_json::to_vec_pretty(marker)?;
    // Atomic marker write so a crash between truncate and write cannot
    // leave a half-written marker that forensic tooling cannot parse.
    let final_path = new_root.join(marker_name);
    let tmp_path = new_root.join(format!("{marker_name}.tmp"));
    fs::write(&tmp_path, bytes)?;
    fs::rename(&tmp_path, &final_path)?;
    Ok(())
}

fn move_contents(from: &Path, to: &Path) -> io::Result<()> {
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let source = entry.path();
        let target = to.join(entry.file_name());
        if let Err(rename_err) = fs::rename(&source, &target) {
            // Cross-volume fallback: copy then delete.
            if rename_err.raw_os_error() == Some(libc::EXDEV) {
                copy_recursive(&source, &target)?;
                remove_recursive(&source)?;
            } else {
                return Err(rename_err);
            }
        }
    }
    Ok(())
}

fn copy_recursive(src: &Path, dst: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(src)?;
    let ty = meta.file_type();
    if ty.is_symlink() {
        // Recreate the symlink at dst instead of following it. fs::copy
        // would dereference and capture the target's contents into a
        // plain file - bad if the link points outside the data root.
        let target = fs::read_link(src)?;
        unix_fs::symlink(target, dst)?;
    } else if ty.is_dir() {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            copy_recursive(&entry.path(), &dst.join(entry.file_name()))?;
        }
    } else {
        fs::copy(src, dst)?;
    }
    Ok(())
}

fn remove_recursive(path: &Path) -> io::Result<()> {
    if path.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn write_marker(new_root: &Path, old_root: &Path) -> Result<(), MigrationError> {
    let marker = Marker {
        from_path: old_root.to_path_buf(),
        migrated_at: Utc::now().to_rfc3339(),
        harness_version: env!("CARGO_PKG_VERSION"),
    };
    write_named_json_marker(new_root, MARKER_NAME, &marker)
}

/// Run the startup data-root migration on macOS. Logs failures and returns;
/// never panics. Callers invoke this once from `dispatch()` at process start.
#[cfg(target_os = "macos")]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn run_startup_migration() {
    use crate::workspace::{harness_data_root, legacy_macos_root};
    if let Err(err) = migrate(&legacy_macos_root(), &harness_data_root()) {
        warn!(%err, "data-root migration failed; continuing with new root");
    }
}

#[cfg(test)]
mod tests;
