//! Resolve a `project_dir` request input that may be either a filesystem path
//! or, on macOS in a sandboxed process, a security-scoped bookmark id.
//!
//! Returns a guard whose `path()` is valid to read while the guard lives.
//! On macOS the guard holds the bookmark's security-scope grant; the daemon
//! must finish any work that touches the origin path before the guard drops,
//! otherwise CFURL revokes
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
    if let Some(scope) = resolve_helper_bookmark(input)? {
        return Ok(Some(scope));
    }
    resolve_shared_bookmark(input)
}

#[cfg(target_os = "macos")]
fn resolve_helper_bookmark(input: &str) -> Result<Option<ProjectInputScope>, CliError> {
    let helper_path = helper_bookmark_store_path();
    let Some(record) = find_bookmark_record(&helper_path, input)? else {
        return Ok(None);
    };
    Ok(resolve_helper_bookmark_record(input, &helper_path, &record))
}

#[cfg(target_os = "macos")]
fn resolve_shared_bookmark(input: &str) -> Result<Option<ProjectInputScope>, CliError> {
    use super::bookmarks;

    let shared_path = shared_bookmark_store_path();
    let shared_store = load_bookmark_store(&shared_path)?;
    let Some(record) = bookmarks::find(&shared_store, input) else {
        return Ok(None);
    };

    let plain_path = resolve_shared_bookmark_path(input, record)?;
    if let Some(scope) = seed_helper_bookmark(input, record, &plain_path)? {
        return Ok(Some(scope));
    }
    Ok(Some(ProjectInputScope {
        path: plain_path,
        _bookmark: None,
    }))
}

#[cfg(target_os = "macos")]
fn resolve_shared_bookmark_path(
    input: &str,
    record: &super::bookmarks::Record,
) -> Result<PathBuf, CliError> {
    let handoff_bytes = record
        .handoff_bookmark_data
        .as_deref()
        .unwrap_or(&record.bookmark_data);
    let plain_resolved = super::resolver::resolve_without_security_scope(handoff_bytes).map_err(
        |error| -> CliError {
            CliErrorKind::workflow_io(format!("resolve bookmark '{input}': {error}")).into()
        },
    )?;
    Ok(plain_resolved.path().to_path_buf())
}

#[cfg(target_os = "macos")]
fn load_bookmark_store(path: &Path) -> Result<super::bookmarks::PersistedStore, CliError> {
    super::bookmarks::load(path).map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!(
            "load bookmarks store '{}': {error}",
            path.display()
        ))
        .into()
    })
}

#[cfg(target_os = "macos")]
fn find_bookmark_record(
    store_path: &Path,
    input: &str,
) -> Result<Option<super::bookmarks::Record>, CliError> {
    use super::bookmarks;

    let store = load_bookmark_store(store_path)?;
    Ok(bookmarks::find(&store, input).cloned())
}

#[cfg(target_os = "macos")]
fn resolve_helper_bookmark_record(
    input: &str,
    helper_path: &Path,
    record: &super::bookmarks::Record,
) -> Option<ProjectInputScope> {
    Some(scope_with_bookmark(try_resolve_helper_scope(
        input,
        helper_path,
        record,
    )?))
}

#[cfg(target_os = "macos")]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn try_resolve_helper_scope(
    input: &str,
    helper_path: &Path,
    record: &super::bookmarks::Record,
) -> Option<ResolvedBookmark> {
    match super::resolver::resolve(&record.bookmark_data) {
        Ok(resolved) => Some(resolved),
        Err(error) => {
            warn!(
                %error,
                bookmark_id = input,
                store = %helper_path.display(),
                "helper-local bookmark resolution failed; attempting shared-store bootstrap"
            );
            None
        }
    }
}

#[cfg(target_os = "macos")]
fn seed_helper_bookmark(
    input: &str,
    record: &super::bookmarks::Record,
    path: &Path,
) -> Result<Option<ProjectInputScope>, CliError> {
    let helper_path = helper_bookmark_store_path();
    let Some(helper_record) = create_helper_bookmark_record(input, record, path) else {
        return Ok(None);
    };
    persist_helper_bookmark_record(input, &helper_path, &helper_record)?;
    resolve_helper_scope(input, &helper_record).map(Some)
}

#[cfg(target_os = "macos")]
fn create_helper_bookmark_record(
    input: &str,
    record: &super::bookmarks::Record,
    path: &Path,
) -> Option<super::bookmarks::Record> {
    let bookmark_data = create_helper_bookmark_data(input, path)?;
    Some(helper_bookmark_record(record, path, bookmark_data))
}

#[cfg(target_os = "macos")]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn create_helper_bookmark_data(input: &str, path: &Path) -> Option<Vec<u8>> {
    match super::resolver::create_security_scoped_bookmark(path) {
        Ok(bookmark_data) => Some(bookmark_data),
        Err(error) => {
            warn!(
                %error,
                bookmark_id = input,
                path = %path.display(),
                "helper-local security-scoped bookmark creation failed; falling back to shared bookmark path"
            );
            None
        }
    }
}

#[cfg(target_os = "macos")]
fn helper_bookmark_record(
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
fn persist_helper_bookmark_record(
    input: &str,
    helper_path: &Path,
    helper_record: &super::bookmarks::Record,
) -> Result<(), CliError> {
    use super::bookmarks;

    let mut helper_store = load_bookmark_store(helper_path)?;
    if let Some(existing) = helper_store
        .bookmarks
        .iter_mut()
        .find(|existing| existing.id == input)
    {
        *existing = helper_record.clone();
    } else {
        helper_store.bookmarks.insert(0, helper_record.clone());
    }
    bookmarks::save(helper_path, &helper_store).map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!(
            "save helper bookmarks store '{}': {error}",
            helper_path.display()
        ))
        .into()
    })
}

#[cfg(target_os = "macos")]
fn resolve_helper_scope(
    input: &str,
    helper_record: &super::bookmarks::Record,
) -> Result<ProjectInputScope, CliError> {
    let resolved =
        super::resolver::resolve(&helper_record.bookmark_data).map_err(|error| -> CliError {
            CliErrorKind::workflow_io(format!("resolve bookmark '{input}': {error}")).into()
        })?;
    Ok(scope_with_bookmark(resolved))
}

#[cfg(target_os = "macos")]
fn scope_with_bookmark(resolved: ResolvedBookmark) -> ProjectInputScope {
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
