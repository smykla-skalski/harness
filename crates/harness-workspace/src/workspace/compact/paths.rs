use std::path::{Path, PathBuf};

use crate::workspace::project_context_dir;

/// Compact directory for a project.
#[must_use]
pub fn compact_project_dir(project_dir: &Path) -> PathBuf {
    project_context_dir(project_dir).join("compact")
}

/// Path to the latest compact handoff file.
#[must_use]
pub fn compact_latest_path(project_dir: &Path) -> PathBuf {
    compact_project_dir(project_dir).join("latest.json")
}

/// History directory for compact handoffs.
#[must_use]
pub fn compact_history_dir(project_dir: &Path) -> PathBuf {
    compact_project_dir(project_dir).join("history")
}
