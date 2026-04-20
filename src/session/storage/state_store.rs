use crate::errors::{CliError, CliErrorKind};
use crate::infra::persistence::versioned_json::VersionedJsonRepository;
use crate::session::types::{CURRENT_VERSION, SessionState};
use crate::workspace::layout::SessionLayout;
use crate::workspace::utc_now;

use super::files;
use super::migrations::{
    migrate_v1_to_v2, migrate_v2_to_v3, migrate_v3_to_v4, migrate_v4_to_v5, migrate_v5_to_v6,
    migrate_v6_to_v7, migrate_v7_to_v8,
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
        Box::new(migrate_v7_to_v8),
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

