//! Per-session directory layout primitives.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionLayout {
    pub sessions_root: PathBuf,
    pub project_name: String,
    pub session_id: String,
}

impl SessionLayout {
    #[must_use]
    pub fn project_dir(&self) -> PathBuf {
        self.sessions_root.join(&self.project_name)
    }

    #[must_use]
    pub fn session_root(&self) -> PathBuf {
        self.project_dir().join(&self.session_id)
    }

    #[must_use]
    pub fn workspace(&self) -> PathBuf {
        self.session_root().join("workspace")
    }

    #[must_use]
    pub fn memory(&self) -> PathBuf {
        self.session_root().join("memory")
    }

    #[must_use]
    pub fn state_file(&self) -> PathBuf {
        self.session_root().join("state.json")
    }

    #[must_use]
    pub fn log_file(&self) -> PathBuf {
        self.session_root().join("log.jsonl")
    }

    #[must_use]
    pub fn tasks_dir(&self) -> PathBuf {
        self.session_root().join("tasks")
    }

    #[must_use]
    pub fn locks_dir(&self) -> PathBuf {
        self.session_root().join(".locks")
    }

    #[must_use]
    pub fn origin_marker(&self) -> PathBuf {
        self.session_root().join(".origin")
    }

    #[must_use]
    pub fn active_registry(&self) -> PathBuf {
        self.project_dir().join(".active.json")
    }

    #[must_use]
    pub fn branch_ref(&self) -> String {
        format!("harness/{}", self.session_id)
    }
}

/// Helper: derive the sessions root from a data root. Returns `<data-root>/sessions`.
#[must_use]
pub fn sessions_root(data_root: &Path) -> PathBuf {
    data_root.join("sessions")
}

#[cfg(test)]
mod tests;
