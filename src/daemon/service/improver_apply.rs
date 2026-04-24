//! Daemon service wrappers for the improver patch apply mutation.
//!
//! Split out of `review_mutations.rs` so the larger review mutation wrapper
//! module stays under the repo-wide file-length cap while exposing
//! `DaemonHttpState`-driven (sync-db, async-db, or file-index) session
//! resolution paths.

use std::path::Path;

use crate::daemon::index as daemon_index;
use crate::daemon::protocol::ImproverApplyRequest;
use crate::errors::CliError;
use crate::session::roles::SessionAction;
use crate::session::service::{self as session_service, ImproverApplyOutcome};
use crate::workspace::utc_now;

use super::{effective_project_dir, index, session_not_found};

/// Apply an improver patch to a canonical skill/plugin source (sync path).
///
/// Resolves the session via the sync daemon DB when provided, falling back
/// to the file index so CLI-only contexts still work. Validates the target
/// path, backs up the existing contents, writes the new body atomically,
/// and returns the outcome. On `dry_run` the validation + diff still run
/// but no files are modified.
///
/// # Errors
/// Returns `CliError` when the path is disallowed, the target is missing,
/// or the write fails.
pub fn improver_apply(
    session_id: &str,
    request: &ImproverApplyRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<ImproverApplyOutcome, CliError> {
    let resolved = if let Some(db) = db {
        db.resolve_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?
    } else {
        index::resolve_session(session_id)?
    };
    apply_improver_from_resolved(&resolved, request)
}

/// Apply an improver patch using the async daemon DB for session resolution.
///
/// # Errors
/// Returns `CliError` on resolution, permission, or write failure.
pub(crate) async fn improver_apply_async(
    session_id: &str,
    request: &ImproverApplyRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<ImproverApplyOutcome, CliError> {
    let resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    apply_improver_from_resolved(&resolved, request)
}

fn apply_improver_from_resolved(
    resolved: &daemon_index::ResolvedSession,
    request: &ImproverApplyRequest,
) -> Result<ImproverApplyOutcome, CliError> {
    session_service::require_permission(
        &resolved.state,
        &request.actor,
        SessionAction::ImproverApply,
    )?;
    let repo_root = effective_project_dir(resolved);
    let rel = Path::new(&request.rel_path);
    let now = utc_now();
    if request.dry_run {
        return session_service::preview_improver_apply(
            repo_root,
            request.target,
            rel,
            &request.new_contents,
        );
    }
    session_service::apply_improver_apply(
        repo_root,
        request.target,
        rel,
        &request.new_contents,
        &request.issue_id,
        &now,
    )
}
