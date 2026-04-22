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
#[cfg(target_os = "macos")]
use std::fmt::Display;
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
    if let Some(scope) = try_resolve_helper_bookmark(input)? {
        return Ok(Some(scope));
    }
    resolve_shared_bookmark(input)
}

#[cfg(target_os = "macos")]
fn try_resolve_helper_bookmark(input: &str) -> Result<Option<ProjectInputScope>, CliError> {
    use super::bookmarks;

    let helper_path = helper_bookmark_store_path();
    let helper_store = load_bookmark_store(&helper_path)?;
    let Some(record) = bookmarks::find(&helper_store, input) else {
        return Ok(None);
    };
    Ok(resolve_helper_record(input, &helper_path, record))
}

#[cfg(target_os = "macos")]
fn resolve_shared_bookmark(input: &str) -> Result<Option<ProjectInputScope>, CliError> {
    use super::bookmarks;

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
    let Some(helper_record) = build_helper_record(input, record, path) else {
        return Ok(None);
    };
    let helper_path = helper_bookmark_store_path();
    let mut helper_store = load_bookmark_store(&helper_path)?;
    upsert_helper_record(&mut helper_store, input, helper_record.clone());
    save_helper_store(&helper_path, &helper_store)?;
    resolve_seeded_helper_bookmark(input, &helper_record)
}

#[cfg(target_os = "macos")]
fn build_helper_record(
    input: &str,
    record: &super::bookmarks::Record,
    path: &Path,
) -> Option<super::bookmarks::Record> {
    let bookmark_data = create_helper_bookmark_data(input, path)?;
    Some(copy_shared_record(record, path, bookmark_data))
}

#[cfg(target_os = "macos")]
fn resolve_helper_record(
    input: &str,
    helper_path: &Path,
    record: &super::bookmarks::Record,
) -> Option<ProjectInputScope> {
    super::resolver::resolve(&record.bookmark_data)
        .map(scope_from_resolved_bookmark)
        .map_err(|error| log_helper_resolution_failure(input, helper_path, &error))
        .ok()
}

#[cfg(target_os = "macos")]
fn create_helper_bookmark_data(input: &str, path: &Path) -> Option<Vec<u8>> {
    super::resolver::create_security_scoped_bookmark(path)
        .map_err(|error| log_helper_creation_failure(input, path, &error))
        .ok()
}

#[cfg(target_os = "macos")]
fn copy_shared_record(
    record: &super::bookmarks::Record,
    path: &Path,
    bookmark_data: Vec<u8>,
) -> super::bookmarks::Record {
    super::bookmarks::Record {
        id: record.id.clone(),
        kind: record.kind.clone(),
        display_name: record.display_name.clone(),
        last_resolved_path: path.display().to_string(),
        bookmark_data,
        handoff_bookmark_data: None,
        created_at: record.created_at,
        last_accessed_at: record.last_accessed_at,
        stale_count: record.stale_count,
    }
}

#[cfg(target_os = "macos")]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_helper_resolution_failure(
    input: &str,
    helper_path: &Path,
    error: &impl Display,
) {
    warn!(
        %error,
        bookmark_id = input,
        store = %helper_path.display(),
        "helper-local bookmark resolution failed; attempting shared-store bootstrap"
    );
}

#[cfg(target_os = "macos")]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_helper_creation_failure(input: &str, path: &Path, error: &impl Display) {
    warn!(
        %error,
        bookmark_id = input,
        path = %path.display(),
        "helper-local security-scoped bookmark creation failed; falling back to shared bookmark path"
    );
}

#[cfg(target_os = "macos")]
fn upsert_helper_record(
    helper_store: &mut super::bookmarks::PersistedStore,
    input: &str,
    helper_record: super::bookmarks::Record,
) {
    if let Some(existing) = helper_store
        .bookmarks
        .iter_mut()
        .find(|existing| existing.id == input)
    {
        *existing = helper_record;
    } else {
        helper_store.bookmarks.insert(0, helper_record);
    }
}

#[cfg(target_os = "macos")]
fn save_helper_store(
    helper_path: &Path,
    helper_store: &super::bookmarks::PersistedStore,
) -> Result<(), CliError> {
    super::bookmarks::save(helper_path, helper_store).map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!(
            "save helper bookmarks store '{}': {error}",
            helper_path.display()
        ))
        .into()
    })
}

#[cfg(target_os = "macos")]
fn resolve_seeded_helper_bookmark(
    input: &str,
    helper_record: &super::bookmarks::Record,
) -> Result<Option<ProjectInputScope>, CliError> {
    let resolved = super::resolver::resolve(&helper_record.bookmark_data).map_err(
        |error| -> CliError {
            CliErrorKind::workflow_io(format!("resolve bookmark '{input}': {error}")).into()
        },
    )?;
    Ok(Some(scope_from_resolved_bookmark(resolved)))
}

#[cfg(target_os = "macos")]
fn scope_from_resolved_bookmark(resolved: ResolvedBookmark) -> ProjectInputScope {
    let path = resolved.path().to_path_buf();
    ProjectInputScope {
        path,
        _bookmark: Some(resolved),
    }
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
