#[cfg(test)]
use std::path::{Path, PathBuf};

pub use harness_protocol::hook::SessionStartHookOutput;

/// Resolve the effective cwd from the hook payload or project dir fallback.
#[must_use]
#[cfg(test)]
pub fn resolve_cwd(payload_cwd: &str, project_dir: &Path) -> PathBuf {
    if !payload_cwd.is_empty() {
        return PathBuf::from(payload_cwd);
    }
    project_dir.to_path_buf()
}

#[cfg(test)]
#[path = "session/tests.rs"]
mod tests;
