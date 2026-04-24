//! Session-creation preparation shared by sync + async daemon paths.
//!
//! Resolves the project bucket, generates the session id, creates the
//! per-session linked checkout, writes initial `state.json`, and registers
//! the session as active. Rolls back on failure so callers see all-or-nothing
//! semantics.

use std::fs;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::sandbox;
use crate::session::types::SessionState;
use crate::workspace::ids;
use crate::workspace::layout::{SessionLayout, sessions_root as workspace_sessions_root};
use crate::workspace::project_resolver;
use crate::workspace::worktree::WorktreeController;
use crate::workspace::{ensure_non_indexable, harness_data_root, project_context_dir, utc_now};

use super::session_service;
use super::session_storage;

pub(super) struct PreparedSession {
    pub(super) layout: SessionLayout,
    pub(super) canonical_origin: PathBuf,
    pub(super) state: SessionState,
}

pub(super) fn prepare_session(
    request: &super::protocol::SessionStartRequest,
) -> Result<PreparedSession, CliError> {
    session_service::validate_policy_preset(request.policy_preset.as_deref())?;

    // Sandboxed callers may pass a bookmark id; the scope guard MUST stay
    // alive while the origin is touched (WorktreeController::create runs the
    // git subprocess against it).
    let project_scope = sandbox::resolve_project_input(&request.project_dir)?;
    let canonical_origin = project_scope.path().to_path_buf();

    let data_root = harness_data_root();
    ensure_non_indexable(&data_root).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "mark harness data root non-indexable: {error}"
        )))
    })?;
    let sessions_root = workspace_sessions_root(&data_root);
    fs::create_dir_all(&sessions_root).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create sessions root '{}': {error}",
            sessions_root.display()
        )))
    })?;
    let project_name =
        project_resolver::resolve_name(&canonical_origin, &sessions_root).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "resolve project name for '{}': {error}",
                canonical_origin.display()
            )))
        })?;

    let session_id = match request.session_id.clone() {
        Some(id) if !id.trim().is_empty() => id,
        _ => ids::new_session_id(),
    };
    let layout = SessionLayout {
        sessions_root,
        project_name: project_name.clone(),
        session_id: session_id.clone(),
    };

    fs::create_dir_all(layout.project_dir()).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create project sessions dir '{}': {error}",
            layout.project_dir().display()
        )))
    })?;
    project_resolver::write_origin_marker(&layout.project_dir(), &canonical_origin).map_err(
        |error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "write project .origin marker for '{}': {error}",
                layout.project_dir().display()
            )))
        },
    )?;

    WorktreeController::create(&canonical_origin, &layout, request.base_ref.as_deref()).map_err(
        |error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "create session worktree: {error}"
            )))
        },
    )?;

    let now = utc_now();
    let mut state = session_service::build_new_session_with_policy(
        &request.context,
        &request.title,
        &session_id,
        "leaderless",
        None,
        &now,
        request.policy_preset.as_deref(),
    );
    state.project_name = project_name;
    state.worktree_path = layout.workspace();
    state.shared_path = layout.memory();
    state.origin_path.clone_from(&canonical_origin);
    state.branch_ref = layout.branch_ref();

    if let Err(error) = session_storage::create_state(&layout, &state) {
        let _ = WorktreeController::destroy(&canonical_origin, &layout);
        return Err(error);
    }
    if let Err(error) = session_storage::register_active(&layout) {
        let _ = WorktreeController::destroy(&canonical_origin, &layout);
        return Err(error);
    }
    let _ = session_storage::record_project_origin(&canonical_origin);
    if !project_context_dir(&canonical_origin).exists() {
        let _ = fs::create_dir_all(project_context_dir(&canonical_origin));
    }

    drop(project_scope);
    Ok(PreparedSession {
        layout,
        canonical_origin,
        state,
    })
}

pub(super) fn rollback_session_artifacts(origin: &Path, layout: &SessionLayout) {
    let _ = session_storage::deregister_active(layout);
    let _ = WorktreeController::destroy(origin, layout);
}
