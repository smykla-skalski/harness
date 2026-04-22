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
use tracing::warn;

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
    let helper_path = helper_bookmark_store_path();
    let helper_store = load_bookmark_store(&helper_path)?;
    if let Some(record) = bookmarks::find(&helper_store, input) {
        match super::resolver::resolve(&record.bookmark_data) {
            Ok(resolved) => {
                let path = resolved.path().to_path_buf();
                return Ok(Some(ProjectInputScope {
                    path,
                    _bookmark: Some(resolved),
                }));
            }
            Err(error) => {
                warn!(
                    %error,
                    bookmark_id = input,
                    store = %helper_path.display(),
                    "helper-local bookmark resolution failed; attempting shared-store bootstrap"
                );
            }
        }
    }

    let shared_path = shared_bookmark_store_path();
    let shared_store = load_bookmark_store(&shared_path)?;
    let Some(record) = bookmarks::find(&shared_store, input) else {
        return Ok(None);
    };

    let handoff_bytes = record
        .handoff_bookmark_data
        .as_deref()
        .unwrap_or(&record.bookmark_data);
    let plain_resolved = super::resolver::resolve_without_security_scope(handoff_bytes).map_err(
        |error| -> CliError {
            CliErrorKind::workflow_io(format!("resolve bookmark '{input}': {error}")).into()
        },
    )?;
    let plain_path = plain_resolved.path().to_path_buf();
    if let Some(scope) = seed_helper_bookmark(input, record, &plain_path)? {
        return Ok(Some(scope));
    }
    Ok(Some(ProjectInputScope {
        path: plain_path,
        _bookmark: None,
    }))
}

#[cfg(target_os = "macos")]
fn load_bookmark_store(path: &Path) -> Result<super::bookmarks::PersistedStore, CliError> {
    super::bookmarks::load(path).map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!("load bookmarks store '{}': {error}", path.display()))
            .into()
    })
}

#[cfg(target_os = "macos")]
fn seed_helper_bookmark(
    input: &str,
    record: &super::bookmarks::Record,
    path: &Path,
) -> Result<Option<ProjectInputScope>, CliError> {
    use super::bookmarks;

    let bookmark_data = match super::resolver::create_security_scoped_bookmark(path) {
        Ok(bookmark_data) => bookmark_data,
        Err(error) => {
            warn!(
                %error,
                bookmark_id = input,
                path = %path.display(),
                "helper-local security-scoped bookmark creation failed; falling back to shared bookmark path"
            );
            return Ok(None);
        }
    };
    let helper_path = helper_bookmark_store_path();
    let mut helper_store = load_bookmark_store(&helper_path)?;
    let helper_record = bookmarks::Record {
        id: record.id.clone(),
        kind: record.kind.clone(),
        display_name: record.display_name.clone(),
        last_resolved_path: path.display().to_string(),
        bookmark_data,
        handoff_bookmark_data: None,
        created_at: record.created_at,
        last_accessed_at: record.last_accessed_at,
        stale_count: record.stale_count,
    };
    if let Some(existing) = helper_store.bookmarks.iter_mut().find(|existing| existing.id == input) {
        *existing = helper_record.clone();
    } else {
        helper_store.bookmarks.insert(0, helper_record.clone());
    }
    bookmarks::save(&helper_path, &helper_store).map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!(
            "save helper bookmarks store '{}': {error}",
            helper_path.display()
        ))
        .into()
    })?;
    let resolved = super::resolver::resolve(&helper_record.bookmark_data).map_err(
        |error| -> CliError {
            CliErrorKind::workflow_io(format!("resolve bookmark '{input}': {error}")).into()
        },
    )?;
    let resolved_path = resolved.path().to_path_buf();
    Ok(Some(ProjectInputScope {
        path: resolved_path,
        _bookmark: Some(resolved),
    }))
}

#[cfg(target_os = "macos")]
fn shared_bookmark_store_path() -> PathBuf {
    let harness_root = harness_data_root();
    harness_root
        .parent()
        .map_or_else(|| harness_root.clone(), Path::to_path_buf)
        .join("sandbox")
        .join("bookmarks.json")
}

#[cfg(target_os = "macos")]
fn helper_bookmark_store_path() -> PathBuf {
    harness_data_root().join("bookmarks.json")
}
