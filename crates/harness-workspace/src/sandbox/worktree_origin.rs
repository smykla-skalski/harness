//! Sandbox grant for the origin project behind a session worktree.
//!
//! A session workspace lives under the sessions root, but it is a *linked* git
//! worktree: its gitdir and object database stay in the origin checkout. A
//! sandboxed daemon therefore cannot read the worktree's git state on the
//! sessions-root grant alone, and gix reports the workspace as "not a git
//! repository". Hold this grant around any git read or write that touches a
//! session worktree.

use std::fs;
use std::path::{Path, PathBuf};

use tracing::warn;

use super::{ProjectInputScope, resolve_path_input};

const ORIGIN_MARKER: &str = ".origin";

/// An active security-scope grant for a worktree's origin checkout.
///
/// Deliberately does not expose the scope's path as a usable directory: the
/// grant covers the origin, while callers keep operating on their own worktree
/// path. Dropping it releases the grant.
pub struct WorktreeOriginGrant {
    origin: Option<PathBuf>,
    _scope: Option<ProjectInputScope>,
}

impl WorktreeOriginGrant {
    /// The origin checkout this grant covers, when one was resolved.
    #[must_use]
    pub fn origin(&self) -> Option<&Path> {
        self.origin.as_deref()
    }

    const fn inert() -> Self {
        Self {
            origin: None,
            _scope: None,
        }
    }
}

/// Hold the origin checkout's sandbox grant for as long as the return value lives.
///
/// Best-effort by design. A missing, unreadable or dangling `.origin` marker
/// yields an inert grant rather than an error, because every caller can already
/// reach worktrees that need no grant at all, and refusing here would turn a
/// working read into a failure.
#[must_use]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn hold_worktree_origin_grant(worktree: &Path) -> WorktreeOriginGrant {
    let Some(origin) = read_origin_marker(worktree) else {
        return WorktreeOriginGrant::inert();
    };
    match resolve_path_input(&origin.to_string_lossy()) {
        Ok(scope) => WorktreeOriginGrant {
            origin: Some(scope.path().to_path_buf()),
            _scope: Some(scope),
        },
        Err(error) => {
            warn!(
                origin = %origin.display(),
                worktree = %worktree.display(),
                %error,
                "session worktree origin could not be granted; git reads may be refused"
            );
            WorktreeOriginGrant::inert()
        }
    }
}

/// Read `<session_root>/.origin` for a `<session_root>/workspace` worktree.
fn read_origin_marker(worktree: &Path) -> Option<PathBuf> {
    let origin = fs::read_to_string(worktree.parent()?.join(ORIGIN_MARKER)).ok()?;
    let origin = origin.trim();
    (!origin.is_empty()).then(|| PathBuf::from(origin))
}

#[cfg(test)]
#[path = "worktree_origin/tests.rs"]
mod tests;
