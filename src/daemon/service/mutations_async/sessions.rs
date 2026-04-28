use super::super::{
    CliError, LeaderTransferRequest, SessionDetail, SessionEndRequest,
    append_transfer_logs_to_async_db, db::AsyncDaemonDb, effective_project_dir,
    session_detail_from_async_daemon_db, session_service, sync_file_state_from_async_db, utc_now,
};
use super::{bump_session, persist_leave_signal_mutation, resolved_session_for_mutation};

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
    session_service::write_prepared_leave_signals(&project_dir, &leave_signals, "end session")?;
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
