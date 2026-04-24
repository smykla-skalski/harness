use std::path::{Path, PathBuf};

use crate::session::types::SessionState;
use crate::workspace::{project_context_dir, project_context_id};

mod contexts;
mod io;
mod paths;
mod projects;
mod reviews;
mod sessions;
#[cfg(test)]
mod tests;

pub use paths::{agent_transcript_path, observe_snapshot_path, signals_root};
pub use projects::{
    discover_projects, discovered_project_for_checkout, discovered_project_for_context_root,
    fast_counts, projects_root,
};
pub use reviews::load_task_reviews;
pub use sessions::{
    discover_sessions, discover_sessions_for, load_conversation_events, load_log_entries,
    load_session_state, load_task_checkpoints, resolve_session,
    resolve_session_id_for_runtime_session,
};

#[derive(Debug, Clone)]
pub struct DiscoveredProject {
    pub project_id: String,
    pub name: String,
    pub project_dir: Option<PathBuf>,
    pub repository_root: Option<PathBuf>,
    pub checkout_id: String,
    pub checkout_name: String,
    pub context_root: PathBuf,
    pub is_worktree: bool,
    pub worktree_name: Option<String>,
}

impl DiscoveredProject {
    #[must_use]
    pub fn summary_project_id(&self) -> String {
        self.repository_root
            .as_deref()
            .and_then(project_context_id)
            .unwrap_or_else(|| self.project_id.clone())
    }

    #[must_use]
    pub fn summary_project_name(&self) -> String {
        self.repository_root
            .as_deref()
            .and_then(path_file_name)
            .unwrap_or_else(|| self.name.clone())
    }

    #[must_use]
    pub fn summary_project_dir(&self) -> Option<String> {
        self.repository_root
            .as_deref()
            .or(self.project_dir.as_deref())
            .map(|path| path.display().to_string())
    }

    #[must_use]
    pub fn summary_context_root(&self) -> String {
        self.repository_root.as_deref().map_or_else(
            || self.context_root.display().to_string(),
            |root| project_context_dir(root).display().to_string(),
        )
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedSession {
    pub project: DiscoveredProject,
    pub state: SessionState,
}

pub(super) fn project_context_dir_name(path: &Path) -> Option<String> {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
}

fn path_file_name(path: &Path) -> Option<String> {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
}
