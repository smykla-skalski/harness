use std::path::PathBuf;

use harness_kernel::errors::{CliError, CliErrorKind};
use harness_session::service as session_service;
use harness_session::wire::{SessionArchiveRequest, SessionArchiveResponse};
use harness_workspace::workspace::utc_now;
use tokio::task::spawn_blocking;

use crate::mutations::{bump_session_async, resolved_session_for_mutation};
use crate::persistence::{build_log_entry, effective_project_dir, session_not_found};
use crate::ports::{AsyncSignalStorage, SignalStorage};

/// # Errors
/// Returns an error when the session cannot be resolved or archiving fails.
pub fn archive_session<S: SignalStorage>(
    session_id: &str,
    request: &SessionArchiveRequest,
    storage: Option<&S>,
) -> Result<SessionArchiveResponse, CliError> {
    let storage = storage.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "daemon database is required for session archive mutations",
        ))
    })?;
    let Some(mut state) = storage.load_session_state_for_mutation(session_id)? else {
        return Err(session_not_found(session_id));
    };
    let archived_at =
        session_service::apply_archive_session(&mut state, &request.actor, &utc_now())?;
    let project_id = storage
        .project_id_for_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    storage.save_session_state(&project_id, &state)?;
    storage.append_log_entry(&build_log_entry(
        session_id,
        session_service::log_session_archived(),
        Some(&request.actor),
        None,
    ))?;
    storage.bump_change(session_id)?;
    storage.bump_change("global")?;
    Ok(SessionArchiveResponse {
        session_id: session_id.to_string(),
        archived_at,
    })
}

/// # Errors
/// Returns an error when the session cannot be resolved or archiving fails.
pub async fn archive_session_async<A: AsyncSignalStorage>(
    session_id: &str,
    request: &SessionArchiveRequest,
    storage: &A,
) -> Result<SessionArchiveResponse, CliError> {
    let project_dir =
        effective_project_dir(&resolved_session_for_mutation(storage, session_id).await?)
            .to_path_buf();
    let now = utc_now();
    let (archived_at, state) = storage
        .update_session_state_immediate(session_id, |state| {
            let archived_at = session_service::apply_archive_session(state, &request.actor, &now)?;
            Ok((archived_at, state.clone()))
        })
        .await?;
    save_archived_file_state_async(project_dir, session_id.to_string(), state).await?;
    storage
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_session_archived(),
            Some(&request.actor),
            None,
        ))
        .await?;
    bump_session_async(storage, session_id).await?;
    Ok(SessionArchiveResponse {
        session_id: session_id.to_string(),
        archived_at,
    })
}

async fn save_archived_file_state_async(
    project_dir: PathBuf,
    session_id: String,
    state: harness_session::types::SessionState,
) -> Result<(), CliError> {
    spawn_blocking(move || {
        let layout = harness_session::storage::layout_from_project_dir(&project_dir, &session_id)?;
        harness_session::storage::save_state(&layout, &state)
    })
    .await
    .unwrap_or_else(|error| {
        Err(CliErrorKind::workflow_io(format!(
            "archive session file mirror worker failed: {error}"
        ))
        .into())
    })
}
