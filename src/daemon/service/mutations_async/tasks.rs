use super::super::{CliError, session_detail_from_async_daemon_db};
use super::super::{
    SessionDetail, TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest,
    TaskQueuePolicyRequest, TaskSource, TaskUpdateRequest, db::AsyncDaemonDb, session_service,
    sync_file_state_from_async_db, utc_now,
};
use super::{append_log, bump_session, persist_task_signal_effects, resolved_session_for_mutation};

/// Create a task through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or task creation fails.
pub(crate) async fn create_task_async(
    session_id: &str,
    request: &TaskCreateRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let spec = session_service::TaskSpec {
        title: &request.title,
        context: request.context.as_deref(),
        severity: request.severity,
        suggested_fix: request.suggested_fix.as_deref(),
        source: TaskSource::Manual,
        observe_issue_id: None,
    };
    let now = utc_now();
    let item = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_create_task(state, &spec, &request.actor, &now)
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    append_log(
        async_db,
        session_id,
        session_service::log_task_created(&spec, &item),
        &request.actor,
    )
    .await?;
    bump_session(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Assign a task through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or assignment fails.
pub(crate) async fn assign_task_async(
    session_id: &str,
    task_id: &str,
    request: &TaskAssignRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let effects = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_assign_task(
                state,
                task_id,
                &request.agent_id,
                &request.actor,
                &now,
            )
        })
        .await?;
    let resolved = resolved_session_for_mutation(async_db, session_id).await?;
    let log = Some(session_service::log_task_assigned(
        task_id,
        &request.agent_id,
    ));
    persist_task_signal_effects(
        async_db,
        &resolved,
        session_id,
        &request.actor,
        &effects,
        log,
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Record a task checkpoint through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or checkpointing fails.
pub(crate) async fn checkpoint_task_async(
    session_id: &str,
    task_id: &str,
    request: &TaskCheckpointRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let checkpoint = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_record_checkpoint(
                state,
                task_id,
                &request.actor,
                &request.summary,
                request.progress,
                &now,
            )
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    async_db.append_checkpoint(session_id, &checkpoint).await?;
    append_log(
        async_db,
        session_id,
        session_service::log_checkpoint_recorded(
            task_id,
            &checkpoint.checkpoint_id,
            request.progress,
        ),
        &request.actor,
    )
    .await?;
    bump_session(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Drop a task onto an extensible target through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the drop is invalid,
/// or task-start signal delivery fails.
pub(crate) async fn drop_task_async(
    session_id: &str,
    task_id: &str,
    request: &TaskDropRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let effects = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_drop_task(
                state,
                task_id,
                &request.target,
                request.queue_policy,
                &request.actor,
                &now,
            )
        })
        .await?;
    let resolved = resolved_session_for_mutation(async_db, session_id).await?;
    persist_task_signal_effects(
        async_db,
        &resolved,
        session_id,
        &request.actor,
        &effects,
        None,
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Update a queued task's reassignment policy through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the task is missing,
/// or queue promotion signal delivery fails.
pub(crate) async fn update_task_queue_policy_async(
    session_id: &str,
    task_id: &str,
    request: &TaskQueuePolicyRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let effects = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_update_task_queue_policy(
                state,
                task_id,
                request.queue_policy,
                &request.actor,
                &now,
            )
        })
        .await?;
    let resolved = resolved_session_for_mutation(async_db, session_id).await?;
    persist_task_signal_effects(
        async_db,
        &resolved,
        session_id,
        &request.actor,
        &effects,
        None,
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Update a task status through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the update fails.
pub(crate) async fn update_task_async(
    session_id: &str,
    task_id: &str,
    request: &TaskUpdateRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let (from_status, effects) = async_db
        .update_session_state_immediate(session_id, |state| {
            let from_status = session_service::apply_update_task(
                state,
                task_id,
                request.status,
                request.note.as_deref(),
                &request.actor,
                &now,
            )?;
            let effects = session_service::apply_advance_queued_tasks(state, &request.actor, &now)?;
            Ok((from_status, effects))
        })
        .await?;
    let resolved = resolved_session_for_mutation(async_db, session_id).await?;
    persist_task_signal_effects(
        async_db,
        &resolved,
        session_id,
        &request.actor,
        &effects,
        Some(session_service::log_task_status_changed(
            task_id,
            from_status,
            request.status,
        )),
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}
