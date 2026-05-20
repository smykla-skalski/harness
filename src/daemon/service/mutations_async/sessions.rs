use super::super::{
    CliError, CliErrorKind, LeaderTransferRequest, SessionDetail, SessionEndRequest,
    append_transfer_logs_to_async_db, db::AsyncDaemonDb, effective_project_dir,
    session_detail_from_async_daemon_db, session_service, sync_file_state_from_async_db, utc_now,
};
use super::{bump_session, persist_leave_signal_mutation, resolved_session_for_mutation};
use crate::daemon::protocol::{SessionArchiveRequest, SessionArchiveResponse};
use crate::session::storage as session_storage;
use tokio::task::spawn_blocking;

/// Transfer session leadership through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub(crate) async fn transfer_leader_async(
    session_id: &str,
    request: &LeaderTransferRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let plan = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_transfer_leader(
                state,
                &request.new_leader_id,
                &request.actor,
                request.reason.as_deref(),
                &now,
            )
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    append_transfer_logs_to_async_db(async_db, session_id, &request.actor, &plan).await?;
    bump_session(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// End a session through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or ending fails.
pub(crate) async fn end_session_async(
    session_id: &str,
    request: &SessionEndRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let project_dir =
        effective_project_dir(&resolved_session_for_mutation(async_db, session_id).await?)
            .to_path_buf();
    let now = utc_now();
    let leave_signals = async_db
        .update_session_state_immediate(session_id, |state| {
            let leave_signals =
                session_service::prepare_end_session_leave_signals(state, &request.actor, &now)?;
            session_service::apply_end_session(state, &request.actor, &now)?;
            Ok(leave_signals)
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    write_prepared_leave_signals_async(project_dir.clone(), leave_signals.clone(), "end session")
        .await?;
    let resolved = resolved_session_for_mutation(async_db, session_id).await?;
    persist_leave_signal_mutation(
        async_db,
        &resolved,
        session_id,
        &request.actor,
        &leave_signals,
        session_service::log_session_ended(),
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Archive a session so daemon reads stop surfacing it to Monitor clients.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or archiving fails.
pub(crate) async fn archive_session_async(
    session_id: &str,
    request: &SessionArchiveRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionArchiveResponse, CliError> {
    let project_dir =
        effective_project_dir(&resolved_session_for_mutation(async_db, session_id).await?)
            .to_path_buf();
    let now = utc_now();
    let (archived_at, state) = async_db
        .update_session_state_immediate(session_id, |state| {
            let archived_at = session_service::apply_archive_session(state, &request.actor, &now)?;
            Ok((archived_at, state.clone()))
        })
        .await?;
    save_archived_file_state_async(project_dir, session_id.to_string(), state).await?;
    super::append_log(
        async_db,
        session_id,
        session_service::log_session_archived(),
        &request.actor,
    )
    .await?;
    bump_session(async_db, session_id).await?;
    Ok(SessionArchiveResponse {
        session_id: session_id.to_string(),
        archived_at,
    })
}

async fn write_prepared_leave_signals_async(
    project_dir: std::path::PathBuf,
    leave_signals: Vec<session_service::LeaveSignalRecord>,
    operation: &'static str,
) -> Result<(), CliError> {
    spawn_blocking(move || {
        session_service::write_prepared_leave_signals(&project_dir, &leave_signals, operation)
    })
    .await
    .unwrap_or_else(|error| {
        Err(
            CliErrorKind::workflow_io(format!("{operation} leave-signal worker failed: {error}"))
                .into(),
        )
    })
}

async fn save_archived_file_state_async(
    project_dir: std::path::PathBuf,
    session_id: String,
    state: crate::session::types::SessionState,
) -> Result<(), CliError> {
    spawn_blocking(move || {
        let layout = session_storage::layout_from_project_dir(&project_dir, &session_id)?;
        session_storage::save_state(&layout, &state)
    })
    .await
    .unwrap_or_else(|error| {
        Err(CliErrorKind::workflow_io(format!(
            "archive session file mirror worker failed: {error}"
        ))
        .into())
    })
}
