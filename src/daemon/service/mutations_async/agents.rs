use std::path::Path;

use super::super::{
    AgentRemoveRequest, CliError, RoleChangeRequest, SessionDetail, build_log_entry,
    db::AsyncDaemonDb, effective_project_dir, session_detail_from_async_daemon_db, session_service,
    slice, sync_file_state_from_async_db, utc_now,
};
use super::{bump_session, persist_leave_signal_mutation, resolved_session_for_mutation};

/// Change an agent role through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the role change fails.
pub(crate) async fn change_role_async(
    session_id: &str,
    agent_id: &str,
    request: &RoleChangeRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let from_role = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_assign_role(state, agent_id, request.role, &request.actor, &now)
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_role_changed(agent_id, from_role, request.role),
            Some(&request.actor),
            request.reason.as_deref(),
        ))
        .await?;
    bump_session(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Remove an agent through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the removal fails.
pub(crate) async fn remove_agent_async(
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let project_dir =
        effective_project_dir(&resolved_session_for_mutation(async_db, session_id).await?)
            .to_path_buf();
    let now = utc_now();
    let leave_signal = async_db
        .update_session_state_immediate(session_id, |state| {
            let signal = session_service::prepare_remove_agent_leave_signal(
                state,
                agent_id,
                &request.actor,
                &now,
            )?;
            session_service::apply_remove_agent(state, agent_id, &request.actor, &now)?;
            Ok(signal)
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    let leave_signals = write_and_collect_leave_signal(leave_signal, &project_dir)?;
    let resolved = resolved_session_for_mutation(async_db, session_id).await?;
    persist_leave_signal_mutation(
        async_db,
        &resolved,
        session_id,
        &request.actor,
        &leave_signals,
        session_service::log_agent_removed(agent_id),
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

fn write_and_collect_leave_signal(
    signal: Option<session_service::LeaveSignalRecord>,
    project_dir: &Path,
) -> Result<Vec<session_service::LeaveSignalRecord>, CliError> {
    let Some(signal) = signal else {
        return Ok(vec![]);
    };
    session_service::write_prepared_leave_signals(
        project_dir,
        slice::from_ref(&signal),
        "remove agent",
    )?;
    Ok(vec![signal])
}
