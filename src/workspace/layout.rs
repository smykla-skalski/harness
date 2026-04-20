//! Per-session directory layout primitives.
//!
//! Pure path composition; nothing here touches the filesystem. Invariants on
//! `project_name` (from [`workspace::project_resolver`]) and `session_id`
//! (from [`workspace::ids::validate`]) are expected to hold upstream before a
//! `SessionLayout` is constructed.

use std::path::{Path, PathBuf};

/// Address of a single session on disk. Every accessor returns a freshly
/// built path; methods do not cache or side-effect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionLayout {
    /// Absolute path to the shared `sessions/` root (typically
    /// `<data-root>/sessions`).
    pub sessions_root: PathBuf,
    /// Project directory name, usually the canonical checkout basename or
    /// `basename-<4hex>` after collision resolution.
    pub project_name: String,
    /// Eight-character lowercase alphanumeric session id.
    pub session_id: String,
}

impl SessionLayout {
    /// `<sessions_root>/<project_name>`.
    #[must_use]
    pub fn project_dir(&self) -> PathBuf {
        self.sessions_root.join(&self.project_name)
    }

    /// `<project_dir>/<session_id>` — the root of everything this session owns.
    #[must_use]
    pub fn session_root(&self) -> PathBuf {
        self.project_dir().join(&self.session_id)
    }

    /// `<session_root>/workspace` — the git worktree managed by the daemon.
    #[must_use]
    pub fn workspace(&self) -> PathBuf {
        self.session_root().join("workspace")
    }

    /// `<session_root>/memory` — shared inter-agent scratch space.
    #[must_use]
    pub fn memory(&self) -> PathBuf {
        self.session_root().join("memory")
    }

    /// `<session_root>/state.json` — persisted session metadata.
    #[must_use]
    pub fn state_file(&self) -> PathBuf {
        self.session_root().join("state.json")
    }

    /// `<session_root>/log.jsonl` — append-only event log.
    #[must_use]
    pub fn log_file(&self) -> PathBuf {
        self.session_root().join("log.jsonl")
    }

    /// `<session_root>/tasks` — task artifacts directory.
    #[must_use]
    pub fn tasks_dir(&self) -> PathBuf {
        self.session_root().join("tasks")
    }

    /// `<session_root>/.locks` — per-session advisory lock directory.
    #[must_use]
    pub fn locks_dir(&self) -> PathBuf {
        self.session_root().join(".locks")
    }

    /// `<session_root>/.origin` — marker recording the canonical origin path.
    #[must_use]
    pub fn origin_marker(&self) -> PathBuf {
        self.session_root().join(".origin")
    }

    /// `<project_dir>/.active.json` — per-project active-session registry.
    #[must_use]
    pub fn active_registry(&self) -> PathBuf {
        self.project_dir().join(".active.json")
    }

    /// `harness/<session_id>` — git branch ref used for the session worktree.
    #[must_use]
    pub fn branch_ref(&self) -> String {
        format!("harness/{}", self.session_id)
    }
}

/// Derive the sessions root from a data root. Returns `<data-root>/sessions`.
#[must_use]
pub fn sessions_root(data_root: &Path) -> PathBuf {
    data_root.join("sessions")
}

#[cfg(test)]
mod tests;
