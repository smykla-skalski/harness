use std::path::PathBuf;

use super::super::{
    AgentRemoveRequest, CliError, CliErrorKind, RoleChangeRequest, SessionDetail, build_log_entry,
    effective_project_dir, prepare_agent_workspace_membership_operation_async,
    session_detail_from_async_daemon_db, session_service, sync_file_state_from_async_db, utc_now,
};
use super::{bump_session, persist_leave_signal_mutation, resolved_session_for_mutation};
use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use harness_protocol::daemon::summaries::AgentWorkspaceMemberOperationOutcome;
use tokio::task::spawn_blocking;

/// Change an agent role through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the role change fails.
pub(crate) async fn change_role_async(
    session_id: &str,
    agent_id: &str,
    request: &RoleChangeRequest,
    async_db: &AsyncDaemonDbHandle,
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
    async_db: &AsyncDaemonDbHandle,
) -> Result<SessionDetail, CliError> {
    let daemon_id =
        prepare_agent_workspace_membership_operation_async(async_db, session_id, agent_id).await?;
    let prepared = prepare_agent_removal(session_id, agent_id, request, async_db).await;
    let (project_dir, leave_signal) = match prepared {
        Ok(prepared) => prepared,
        Err(error) => {
            let detail = error.message();
            if let Err(record_error) = async_db
                .record_agent_workspace_membership_removal(
                    &daemon_id,
                    session_id,
                    agent_id,
                    AgentWorkspaceMemberOperationOutcome::Failed,
                    Some(&detail),
                )
                .await
            {
                tracing::warn!(
                    error = %record_error,
                    session_id,
                    agent_id,
                    "failed to record unsuccessful membership removal"
                );
            }
            return Err(error);
        }
    };
    let recorded = async_db
        .record_agent_workspace_membership_removal(
            &daemon_id,
            session_id,
            agent_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await;
    let finalized = finalize_agent_removal(
        session_id,
        agent_id,
        request,
        async_db,
        project_dir,
        leave_signal,
    )
    .await;
    match (finalized, recorded) {
        (Ok(detail), Ok(true)) => Ok(detail),
        (Err(error), Ok(true)) => Err(error),
        (Ok(_), Ok(false)) => Err(CliErrorKind::workflow_io(
            "membership removed but no durable member accepted the result",
        )
        .into()),
        (Err(finalize_error), Ok(false)) => Err(CliErrorKind::workflow_io(format!(
            "membership removed but no durable member accepted the result; post-removal finalization also failed: {}",
            finalize_error.message()
        ))
        .into()),
        (Ok(_), Err(error)) => Err(CliErrorKind::workflow_io(format!(
            "membership removed but durable result recording failed: {}",
            error.message()
        ))
        .into()),
        (Err(finalize_error), Err(record_error)) => Err(CliErrorKind::workflow_io(format!(
            "membership removed but durable result recording failed: {}; post-removal finalization also failed: {}",
            record_error.message(),
            finalize_error.message()
        ))
        .into()),
    }
}

async fn prepare_agent_removal(
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
    async_db: &AsyncDaemonDbHandle,
) -> Result<(PathBuf, Option<session_service::LeaveSignalRecord>), CliError> {
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
    Ok((project_dir, leave_signal))
}

async fn finalize_agent_removal(
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
    async_db: &AsyncDaemonDbHandle,
    project_dir: PathBuf,
    leave_signal: Option<session_service::LeaveSignalRecord>,
) -> Result<SessionDetail, CliError> {
    sync_file_state_from_async_db(async_db, session_id).await?;
    let leave_signals = write_and_collect_leave_signal_async(leave_signal, project_dir).await?;
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

async fn write_and_collect_leave_signal_async(
    signal: Option<session_service::LeaveSignalRecord>,
    project_dir: PathBuf,
) -> Result<Vec<session_service::LeaveSignalRecord>, CliError> {
    let Some(signal) = signal else {
        return Ok(vec![]);
    };
    let leave_signals = vec![signal];
    let signals_for_write = leave_signals.clone();
    spawn_blocking(move || {
        session_service::write_prepared_leave_signals(
            &project_dir,
            &signals_for_write,
            "remove agent",
        )
    })
    .await
    .unwrap_or_else(|error| {
        Err(
            CliErrorKind::workflow_io(format!("remove agent leave-signal worker failed: {error}"))
                .into(),
        )
    })?;
    Ok(leave_signals)
}
