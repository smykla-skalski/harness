//! Startup sweep: remove session directories missing `state.json`.

use std::fs;
use std::io;
use std::path::Path;

use tracing::info;

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
        let project = project_entry?.path();
        if !project.is_dir() {
            continue;
        }
        for session_entry in fs::read_dir(&project)? {
            let session_dir = session_entry?.path();
            if !session_dir.is_dir() {
                continue;
            }
            let name = session_dir
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("");
            if name.starts_with('.') {
                continue;
            }
            if !session_dir.join("state.json").exists() {
                info!(path = %session_dir.display(), "removing orphaned session dir");
                fs::remove_dir_all(&session_dir)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
