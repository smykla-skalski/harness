//! One-shot migration from the legacy `~/Library/Application Support/harness`
//! data root to the new app-group-container root.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::Serialize;
use thiserror::Error;
use tracing::{info, warn};

#[derive(Debug)]
pub enum MigrationOutcome {
    Migrated,
    AlreadyMigrated,
    SkippedOldAbsent,
    SkippedNewNotEmpty,
}

#[derive(Debug, Error)]
pub enum MigrationError {
    #[error("I/O: {0}")]
    Io(#[from] io::Error),
    #[error("serde: {0}")]
    Serde(#[from] serde_json::Error),
}

const MARKER_NAME: &str = ".migrated-from";

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
    move_contents(old_root, new_root)?;
    write_marker(new_root, old_root)?;
    info!(from = %old_root.display(), to = %new_root.display(), "migrated data root");
    Ok(MigrationOutcome::Migrated)
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
    if src.is_dir() {
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
    fs::write(new_root.join(MARKER_NAME), bytes)?;
    Ok(())
}

#[cfg(test)]
mod tests;
