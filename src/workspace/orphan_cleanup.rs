//! Startup sweep: remove session directories missing `state.json`.
//!
//! Callers MUST run this before the daemon listener binds, or the sweep may
//! race with an in-flight session create that hasn't written state.json yet.

use std::fs;
use std::io;
use std::path::Path;

use tracing::{info, warn};

/// # Errors
/// Returns `io::Error` on filesystem enumeration/removal errors.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn cleanup_orphans(sessions_root: &Path) -> io::Result<()> {
    if !sessions_root.exists() {
        return Ok(());
    }
    for project_entry in fs::read_dir(sessions_root)? {
        let project = match project_entry {
            Ok(entry) => entry.path(),
            Err(err) => {
                warn!(%err, "failed to read project entry during orphan sweep");
                continue;
            }
        };
        let Ok(project_meta) = fs::symlink_metadata(&project) else {
            continue;
        };
        if !project_meta.file_type().is_dir() {
            continue;
        }
        let session_iter = match fs::read_dir(&project) {
            Ok(iter) => iter,
            Err(err) => {
                warn!(%err, path = %project.display(), "failed to read project dir during orphan sweep");
                continue;
            }
        };
        for session_entry in session_iter {
            let session_dir = match session_entry {
                Ok(entry) => entry.path(),
                Err(err) => {
                    warn!(%err, "failed to read session entry during orphan sweep");
                    continue;
                }
            };
            let Ok(session_meta) = fs::symlink_metadata(&session_dir) else {
                continue;
            };
            let file_type = session_meta.file_type();
            if file_type.is_symlink() {
                continue;
            }
            if !file_type.is_dir() {
                continue;
            }
            let Some(name) = session_dir.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if name.starts_with('.') {
                continue;
            }
            if !session_dir.join("state.json").exists() {
                info!(path = %session_dir.display(), "removing orphaned session dir");
                if let Err(err) = fs::remove_dir_all(&session_dir) {
                    warn!(%err, path = %session_dir.display(), "orphan cleanup failed");
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
