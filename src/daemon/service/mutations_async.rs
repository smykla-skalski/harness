use crate::daemon::index::ResolvedSession;

use super::{
    CliError, LeaderTransferRequest, RoleChangeRequest, SessionDetail, TaskAssignRequest,
    TaskCheckpointRequest, TaskCreateRequest, TaskSource, append_transfer_logs_to_async_db,
    build_log_entry, session_detail_async, session_not_found, session_service, utc_now,
};

async fn resolved_session_for_mutation(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
) -> Result<ResolvedSession, CliError> {
    async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))
}

async fn bump_session(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
) -> Result<(), CliError> {
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await
}

/// Create a task through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or task creation fails.
pub(crate) async fn create_task_async(
    session_id: &str,
    request: &TaskCreateRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let spec = session_service::TaskSpec {
        title: &request.title,
        context: request.context.as_deref(),
        severity: request.severity,
        suggested_fix: request.suggested_fix.as_deref(),
        source: TaskSource::Manual,
        observe_issue_id: None,
    };
    let mut resolved = resolved_session_for_mutation(async_db, session_id).await?;
    let item =
        session_service::apply_create_task(&mut resolved.state, &spec, &request.actor, &utc_now())?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_created(&spec, &item),
            Some(&request.actor),
            None,
        ))
        .await?;
    bump_session(async_db, session_id).await?;
    session_detail_async(session_id, Some(async_db)).await
}

/// Assign a task through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or assignment fails.
pub(crate) async fn assign_task_async(
    session_id: &str,
    task_id: &str,
    request: &TaskAssignRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let mut resolved = resolved_session_for_mutation(async_db, session_id).await?;
    session_service::apply_assign_task(
        &mut resolved.state,
        task_id,
        &request.agent_id,
        &request.actor,
        &utc_now(),
    )?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_assigned(task_id, &request.agent_id),
            Some(&request.actor),
            None,
        ))
        .await?;
    bump_session(async_db, session_id).await?;
    session_detail_async(session_id, Some(async_db)).await
}

/// Record a task checkpoint through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or checkpointing fails.
pub(crate) async fn checkpoint_task_async(
    session_id: &str,
    task_id: &str,
    request: &TaskCheckpointRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let mut resolved = resolved_session_for_mutation(async_db, session_id).await?;
    let checkpoint = session_service::apply_record_checkpoint(
        &mut resolved.state,
        task_id,
        &request.actor,
        &request.summary,
        request.progress,
        &utc_now(),
    )?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    async_db.append_checkpoint(session_id, &checkpoint).await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_checkpoint_recorded(
                task_id,
                &checkpoint.checkpoint_id,
                request.progress,
            ),
            Some(&request.actor),
            None,
        ))
        .await?;
    bump_session(async_db, session_id).await?;
    session_detail_async(session_id, Some(async_db)).await
}

/// Change an agent role through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the role change fails.
pub(crate) async fn change_role_async(
    session_id: &str,
    agent_id: &str,
    request: &RoleChangeRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let mut resolved = resolved_session_for_mutation(async_db, session_id).await?;
    let from_role = session_service::apply_assign_role(
        &mut resolved.state,
        agent_id,
        request.role,
        &request.actor,
        &utc_now(),
    )?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_role_changed(agent_id, from_role, request.role),
            Some(&request.actor),
            request.reason.as_deref(),
        ))
        .await?;
    bump_session(async_db, session_id).await?;
    session_detail_async(session_id, Some(async_db)).await
}

/// Transfer session leadership through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub(crate) async fn transfer_leader_async(
    session_id: &str,
    request: &LeaderTransferRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let mut resolved = resolved_session_for_mutation(async_db, session_id).await?;
    let plan = session_service::apply_transfer_leader(
        &mut resolved.state,
        &request.new_leader_id,
        &request.actor,
        request.reason.as_deref(),
        &utc_now(),
    )?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    append_transfer_logs_to_async_db(async_db, session_id, &request.actor, &plan).await?;
    bump_session(async_db, session_id).await?;
    session_detail_async(session_id, Some(async_db)).await
}
