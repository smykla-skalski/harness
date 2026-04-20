use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::persistence::versioned_json::VersionedJsonRepository;
use crate::session::types::{CURRENT_VERSION, SessionState};
use crate::workspace::layout::SessionLayout;
use crate::workspace::utc_now;

use super::files;
use super::migrations::{
    migrate_v1_to_v2, migrate_v2_to_v3, migrate_v3_to_v4, migrate_v4_to_v5, migrate_v5_to_v6,
    migrate_v6_to_v7,
};

/// Build a `VersionedJsonRepository` for the session state file.
fn state_repository(
    layout: &SessionLayout,
) -> VersionedJsonRepository<SessionState> {
    VersionedJsonRepository::new(files::state_path(layout), CURRENT_VERSION).with_migrations(vec![
        Box::new(migrate_v1_to_v2),
        Box::new(migrate_v2_to_v3),
        Box::new(migrate_v3_to_v4),
        Box::new(migrate_v4_to_v5),
        Box::new(migrate_v5_to_v6),
        Box::new(migrate_v6_to_v7),
    ])
}

/// Load session state, returning `None` if the state file does not exist.
///
/// # Errors
/// Returns `CliError` on I/O or parse failures.
pub(crate) fn load_state(layout: &SessionLayout) -> Result<Option<SessionState>, CliError> {
    state_repository(layout).load()
}

/// Save session state only when the session does not already exist.
///
/// # Errors
/// Returns `CliError` on I/O or serialization failures.
pub(crate) fn create_state(
    layout: &SessionLayout,
    state: &SessionState,
) -> Result<bool, CliError> {
    files::validate_session_id(&layout.session_id)?;
    let repository = state_repository(layout);
    let mut created = false;
    let _ = repository.update(|current| {
        if current.is_some() {
            return Ok(current);
        }
        created = true;
        Ok(Some(state.clone()))
    })?;
    Ok(created)
}

/// Load, modify, and save session state under an exclusive lock.
///
/// # Errors
/// Returns `CliError` on I/O, parse, or serialization failures, or if state is missing.
pub(crate) fn update_state<F>(layout: &SessionLayout, update: F) -> Result<SessionState, CliError>
where
    F: FnOnce(&mut SessionState) -> Result<(), CliError>,
{
    let session_id = layout.session_id.clone();
    state_repository(layout)
        .update(|state| {
            let Some(mut state) = state else {
                return Err(CliErrorKind::session_not_active(format!(
                    "session '{session_id}' not found"
                ))
                .into());
            };
            state.state_version += 1;
            state.updated_at = utc_now();
            update(&mut state)?;
            Ok(Some(state))
        })
        .and_then(|result| {
            result.ok_or_else(|| {
                CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
            })
        })
}

/// Load, modify, and save session state only when the closure reports a
/// meaningful change.
///
/// The closure returns `true` when the state should be persisted. No-op
/// updates return the current state without rewriting the file.
///
/// # Errors
/// Returns `CliError` on I/O, parse, or serialization failures, or if state is missing.
pub(crate) fn update_state_if_changed<F>(
    layout: &SessionLayout,
    update: F,
) -> Result<SessionState, CliError>
where
    F: FnOnce(&mut SessionState) -> Result<bool, CliError>,
{
    let session_id = layout.session_id.clone();
    state_repository(layout)
        .update(|state| {
            let Some(mut state) = state else {
                return Err(CliErrorKind::session_not_active(format!(
                    "session '{session_id}' not found"
                ))
                .into());
            };
            let changed = update(&mut state)?;
            if changed {
                state.state_version += 1;
                state.updated_at = utc_now();
            }
            Ok(Some(state))
        })
        .and_then(|result| {
            result.ok_or_else(|| {
                CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
            })
        })
}

// ---------------------------------------------------------------------------
// Legacy adapters — callers not yet migrated to `SessionLayout`.
// Every call site carries `TODO(b-task-8)`.
// ---------------------------------------------------------------------------

/// Legacy: load state by `project_dir` + `session_id`.
///
/// # TODO(b-task-8): migrate callers to `load_state(layout)`.
pub(crate) fn load_state_legacy(
    project_dir: &Path,
    session_id: &str,
) -> Result<Option<SessionState>, CliError> {
    let layout = files::layout_from_project_dir(project_dir, session_id);
    load_state(&layout)
}

/// Legacy: create state by `project_dir` + `session_id`.
///
/// # TODO(b-task-8): migrate callers to `create_state(layout, state)`.
pub(crate) fn create_state_legacy(
    project_dir: &Path,
    session_id: &str,
    state: &SessionState,
) -> Result<bool, CliError> {
    let layout = files::layout_from_project_dir(project_dir, session_id);
    create_state(&layout, state)
}

/// Legacy: update state by `project_dir` + `session_id`.
///
/// # TODO(b-task-8): migrate callers to `update_state(layout, fn)`.
pub(crate) fn update_state_legacy<F>(
    project_dir: &Path,
    session_id: &str,
    update: F,
) -> Result<SessionState, CliError>
where
    F: FnOnce(&mut SessionState) -> Result<(), CliError>,
{
    let layout = files::layout_from_project_dir(project_dir, session_id);
    update_state(&layout, update)
}

/// Legacy: update state if changed by `project_dir` + `session_id`.
///
/// # TODO(b-task-8): migrate callers to `update_state_if_changed(layout, fn)`.
pub(crate) fn update_state_if_changed_legacy<F>(
    project_dir: &Path,
    session_id: &str,
    update: F,
) -> Result<SessionState, CliError>
where
    F: FnOnce(&mut SessionState) -> Result<bool, CliError>,
{
    let layout = files::layout_from_project_dir(project_dir, session_id);
    update_state_if_changed(&layout, update)
}
