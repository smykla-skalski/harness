//! One-shot migration from the legacy `~/Library/Application Support/harness`
//! data root to the new app-group-container root.

use std::fs;
use std::io;
use std::os::unix::fs as unix_fs;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::Serialize;
use thiserror::Error;
use tracing::{info, warn};

#[must_use]
#[derive(Debug)]
pub enum MigrationOutcome {
    Migrated,
    AlreadyMigrated,
    SkippedOldAbsent,
    SkippedNewNotEmpty,
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
const LOCK_NAME: &str = ".migration.lock";

#[derive(Debug, Serialize)]
struct Marker {
    from_path: PathBuf,
    migrated_at: String,
    harness_version: &'static str,
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
    if new_root.join(MARKER_NAME).exists() {
        return Ok(MigrationOutcome::AlreadyMigrated);
    }
    if !old_root.exists() || dir_is_empty(old_root)? {
        return Ok(MigrationOutcome::SkippedOldAbsent);
    }
    if new_root.exists() && !dir_is_empty(new_root)? {
        warn!(old = %old_root.display(), new = %new_root.display(),
              "data-root split: both old and new have content; new wins, leaving old in place");
        return Ok(MigrationOutcome::SkippedNewNotEmpty);
    }

    fs::create_dir_all(new_root)?;
    let Some(_lock) = acquire_lock(new_root)? else {
        // Another process is mid-migration; back off.
        return Ok(MigrationOutcome::ConcurrentlyMigrating);
    };
    move_contents(old_root, new_root)?;
    write_marker(new_root, old_root)?;
    info!(from = %old_root.display(), to = %new_root.display(), "migrated data root");
    Ok(MigrationOutcome::Migrated)
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

fn dir_is_empty(path: &Path) -> io::Result<bool> {
    Ok(fs::read_dir(path)?.next().is_none())
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
    let bytes = serde_json::to_vec_pretty(&marker)?;
    // Atomic marker write so a crash between truncate and write cannot
    // leave a half-written marker that forensic tooling cannot parse.
    let final_path = new_root.join(MARKER_NAME);
    let tmp_path = new_root.join(format!("{MARKER_NAME}.tmp"));
    fs::write(&tmp_path, bytes)?;
    fs::rename(&tmp_path, &final_path)?;
    Ok(())
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
