//! Resolve a `project_dir` request input that may be either a filesystem path
//! or, on macOS in a sandboxed process, a security-scoped bookmark id.
//!
//! Returns a guard whose `path()` is valid to read while the guard lives.
//! On macOS the guard holds the bookmark's security-scope grant; the daemon
//! must finish any work that touches the origin path (notably
//! `git worktree add`) before the guard drops, otherwise CFURL revokes
//! access mid-operation. Filesystem work under the sessions root does not
//! need the scope active.

use std::fs;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
#[cfg(target_os = "macos")]
use crate::workspace::harness_data_root;

#[cfg(target_os = "macos")]
use super::resolver::ResolvedBookmark;

/// Resolved project-dir input plus optional security-scope guard.
///
/// Drop releases the bookmark scope (no-op on non-macOS / non-sandboxed
/// callers, which carry only the canonicalized path).
pub struct ProjectInputScope {
    path: PathBuf,
    #[cfg(target_os = "macos")]
    _bookmark: Option<ResolvedBookmark>,
}

impl ProjectInputScope {
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Resolve `input` to a usable project directory path.
///
/// macOS sandboxed callers may pass a bookmark id (the `id` field of a record
/// in `bookmarks.json` shared with the Monitor app); when the id matches a
/// stored bookmark, the resolver fetches and activates the security scope.
/// Every other path (non-macOS, non-sandboxed, or bookmark id miss) treats
/// the input as a filesystem path and canonicalizes it.
///
/// # Errors
/// Returns `CliError` when canonicalization fails or, on macOS, when a
/// matching bookmark cannot be resolved by Core Foundation.
pub fn resolve_project_input(input: &str) -> Result<ProjectInputScope, CliError> {
    #[cfg(target_os = "macos")]
    {
        if super::resolver::is_sandboxed()
            && let Some(scope) = try_resolve_bookmark(input)?
        {
            return Ok(scope);
        }
    }
    let path = fs::canonicalize(input).map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!(
            "session start could not canonicalize project_dir '{input}': {error}"
        ))
        .into()
    })?;
    Ok(ProjectInputScope {
        path,
        #[cfg(target_os = "macos")]
        _bookmark: None,
    })
}

#[cfg(test)]
mod tests;

#[cfg(target_os = "macos")]
fn try_resolve_bookmark(input: &str) -> Result<Option<ProjectInputScope>, CliError> {
    use super::bookmarks;
    for store_path in bookmark_store_paths() {
        let store = bookmarks::load(&store_path).map_err(|error| -> CliError {
            CliErrorKind::workflow_io(format!(
                "load bookmarks store '{}': {error}",
                store_path.display()
            ))
            .into()
        })?;
        let Some(record) = bookmarks::find(&store, input) else {
            continue;
        };
        let resolved =
            super::resolver::resolve(&record.bookmark_data).map_err(|error| -> CliError {
                CliErrorKind::workflow_io(format!("resolve bookmark '{input}': {error}")).into()
            })?;
        let path = resolved.path().to_path_buf();
        return Ok(Some(ProjectInputScope {
            path,
            _bookmark: Some(resolved),
        }));
    }
    Ok(None)
}

#[cfg(target_os = "macos")]
fn bookmark_store_paths() -> [PathBuf; 2] {
    let harness_root = harness_data_root();
    let shared_root = harness_root
        .parent()
        .map_or_else(|| harness_root.clone(), Path::to_path_buf);
    [
        shared_root.join("sandbox").join("bookmarks.json"),
        harness_root.join("bookmarks.json"),
    ]
}
