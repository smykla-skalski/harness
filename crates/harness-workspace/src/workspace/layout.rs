//! Per-checkout directory layout primitives.
//!
//! Pure path composition; nothing here touches the filesystem. Invariants on
//! `project_name` (from [`workspace::project_resolver`]) and `session_id`
//! (from [`workspace::ids::validate`]) are expected to hold upstream before a
//! `SessionLayout` is constructed.

use std::path::{Path, PathBuf};

/// What [`super::worktree::WorktreeController`] needs to create or destroy a
/// linked checkout, independent of who owns it.
///
/// A `SessionLayout` and a [`WorkingCopyLayout`] name checkouts under different
/// roots on purpose: the startup orphan sweep deletes any directory under
/// `sessions/` that has no `state.json`, so a Session-less checkout parked
/// there would not survive a daemon restart.
pub trait CheckoutLayout {
    /// Name git registers the linked worktree under.
    fn checkout_name(&self) -> &str;
    /// Root of everything this checkout owns.
    fn checkout_root(&self) -> PathBuf;
    /// The linked checkout itself.
    fn workspace(&self) -> PathBuf;
    /// Shared scratch space beside the checkout.
    fn memory(&self) -> PathBuf;
    /// Marker recording the canonical origin path.
    fn origin_marker(&self) -> PathBuf;
    /// Branch ref the checkout is created on.
    fn branch_ref(&self) -> String;
}

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
    /// Harness session id. Generated and explicit ids must be lowercase UUIDs.
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

    /// `<session_root>/workspace` — the linked checkout managed by the daemon.
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

// Spelled as associated-function calls so the inherent methods stay the source
// of truth; `self.workspace()` inside this block reads like recursion even
// though inherent resolution wins.
impl CheckoutLayout for SessionLayout {
    fn checkout_name(&self) -> &str {
        &self.session_id
    }

    fn checkout_root(&self) -> PathBuf {
        Self::session_root(self)
    }

    fn workspace(&self) -> PathBuf {
        Self::workspace(self)
    }

    fn memory(&self) -> PathBuf {
        Self::memory(self)
    }

    fn origin_marker(&self) -> PathBuf {
        Self::origin_marker(self)
    }

    fn branch_ref(&self) -> String {
        Self::branch_ref(self)
    }
}

/// Address of a single Session-less working copy on disk.
///
/// Mirrors [`SessionLayout`] under a separate root so a checkout owned by a
/// durable workspace never looks like a half-written Session to the orphan
/// sweep.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkingCopyLayout {
    /// Absolute path to the shared `working-copies/` root (typically
    /// `<data-root>/working-copies`).
    pub working_copies_root: PathBuf,
    /// Project directory name, resolved the same way sessions resolve theirs.
    pub project_name: String,
    /// Durable working-copy id. Generated ids are lowercase UUIDs.
    pub working_copy_id: String,
}

impl WorkingCopyLayout {
    /// `<working_copies_root>/<project_name>`.
    #[must_use]
    pub fn project_dir(&self) -> PathBuf {
        self.working_copies_root.join(&self.project_name)
    }

    /// `<project_dir>/<working_copy_id>` — the root of everything this working
    /// copy owns.
    #[must_use]
    pub fn working_copy_root(&self) -> PathBuf {
        self.project_dir().join(&self.working_copy_id)
    }
}

impl CheckoutLayout for WorkingCopyLayout {
    fn checkout_name(&self) -> &str {
        &self.working_copy_id
    }

    fn checkout_root(&self) -> PathBuf {
        self.working_copy_root()
    }

    fn workspace(&self) -> PathBuf {
        self.working_copy_root().join("workspace")
    }

    fn memory(&self) -> PathBuf {
        self.working_copy_root().join("memory")
    }

    fn origin_marker(&self) -> PathBuf {
        self.working_copy_root().join(".origin")
    }

    fn branch_ref(&self) -> String {
        format!("harness/{}", self.working_copy_id)
    }
}

/// Derive the sessions root from a data root. Returns `<data-root>/sessions`.
#[must_use]
pub fn sessions_root(data_root: &Path) -> PathBuf {
    data_root.join("sessions")
}

/// Derive the working-copies root from a data root. Returns
/// `<data-root>/working-copies`, deliberately a sibling of `sessions/` so the
/// Session orphan sweep never walks it.
#[must_use]
pub fn working_copies_root(data_root: &Path) -> PathBuf {
    data_root.join("working-copies")
}

#[cfg(test)]
#[path = "layout/tests.rs"]
mod tests;
