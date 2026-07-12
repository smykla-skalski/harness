use super::super::wake_route::WakeDispatch;
use super::super::{CliError, session_detail_from_async_daemon_db};
use super::super::{
    CliErrorKind, SessionDetail, TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest,
    TaskDeleteRequest, TaskDropRequest, TaskQueuePolicyRequest, TaskSource, TaskUpdateRequest,
    db::AsyncDaemonDb, session_not_found, session_service, sync_file_state_from_async_db, utc_now,
};
use super::{append_log, bump_session, persist_task_signal_effects, resolved_session_for_mutation};
use crate::infra::io::validate_safe_segment;
use crate::session::types::{SessionState, TaskStatus, WorkItem};

struct DeleteRollback<'a> {
    project_id: &'a str,
    state: &'a SessionState,
}

struct DeleteTaskMutation {
    rollback_project_id: String,
    rollback_state: SessionState,
    deleted_title: String,
    deleted_previous_status: TaskStatus,
    effects: Vec<session_service::TaskDropEffect>,
}

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

/// Idempotently create a task with an identity reserved by durable dispatch.
#[expect(
    clippy::cognitive_complexity,
    reason = "idempotent task creation validates reserved state before synchronizing mirrors and audit data"
)]
pub(crate) async fn create_task_with_id_async(
    session_id: &str,
    task_id: &str,
    request: &TaskCreateRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    validate_safe_segment(task_id)?;
    let spec = session_service::TaskSpec {
        title: &request.title,
        context: request.context.as_deref(),
        severity: request.severity,
        suggested_fix: request.suggested_fix.as_deref(),
        source: TaskSource::Manual,
        observe_issue_id: None,
    };
    let now = utc_now();
    let created = async_db
        .update_session_state_immediate(session_id, |state| {
            if let Some(existing) = state.tasks.get(task_id) {
                ensure_reserved_task_matches(existing, &spec)?;
                return Ok(false);
            }
            session_service::apply_create_task_with_id(
                state,
                task_id,
                &spec,
                &request.actor,
                &now,
            )?;
            Ok(true)
        })
        .await?;
    // The task row may have been committed by an earlier preparation attempt
    // that crashed before its file mirror was refreshed. Re-sync on both the
    // create and idempotent-retry paths.
    sync_file_state_from_async_db(async_db, session_id).await?;
    if created {
        let item = async_db
            .resolve_session(session_id)
            .await?
            .and_then(|resolved| resolved.state.tasks.get(task_id).cloned())
            .ok_or_else(|| session_not_found(session_id))?;
        append_log(
            async_db,
            session_id,
            session_service::log_task_created(&spec, &item),
            &request.actor,
        )
        .await?;
    }
    bump_session(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

fn ensure_reserved_task_matches(
    item: &WorkItem,
    spec: &session_service::TaskSpec<'_>,
) -> Result<(), CliError> {
    let matches = item.title == spec.title
        && item.context.as_deref() == spec.context
        && item.severity == spec.severity
        && item.suggested_fix.as_deref() == spec.suggested_fix
        && item.source == spec.source;
    if matches {
        return Ok(());
    }
    Err(CliErrorKind::session_agent_conflict(format!(
        "reserved task '{}' already exists with different content",
        item.task_id
    ))
    .into())
}

/// Delete a task from active task views while preserving timeline history.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or task deletion fails.
pub(crate) async fn delete_task_async(
    session_id: &str,
    task_id: &str,
    request: &TaskDeleteRequest,
    async_db: &AsyncDaemonDb,
    dispatch: WakeDispatch<'_>,
) -> Result<SessionDetail, CliError> {
    let mutation =
        prepare_delete_task_mutation(async_db, session_id, task_id, &request.actor).await?;
    let rollback = DeleteRollback {
        project_id: &mutation.rollback_project_id,
        state: &mutation.rollback_state,
    };
    persist_delete_audit_or_rollback(async_db, session_id, task_id, request, &mutation, &rollback)
        .await?;
    let resolved = resolved_session_for_mutation(async_db, session_id).await?;
    persist_task_signal_effects(
        async_db,
        &resolved,
        session_id,
        &request.actor,
        &mutation.effects,
        None,
        dispatch,
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

async fn prepare_delete_task_mutation(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    task_id: &str,
    actor_id: &str,
) -> Result<DeleteTaskMutation, CliError> {
    let rollback = resolved_session_for_mutation(async_db, session_id).await?;
    let now = utc_now();
    let (deleted, effects) = async_db
        .update_session_state_immediate(session_id, |state| {
            let deleted = session_service::apply_delete_task(state, task_id, actor_id, &now)?;
            let effects = session_service::apply_advance_queued_tasks(state, actor_id, &now)?;
            Ok((deleted, effects))
        })
        .await?;
    Ok(DeleteTaskMutation {
        rollback_project_id: rollback.project.project_id,
        rollback_state: rollback.state,
        deleted_title: deleted.title,
        deleted_previous_status: deleted.previous_status,
        effects,
    })
}

async fn persist_delete_audit_or_rollback(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    task_id: &str,
    request: &TaskDeleteRequest,
    mutation: &DeleteTaskMutation,
    rollback: &DeleteRollback<'_>,
) -> Result<(), CliError> {
    rollback_delete_step(
        sync_file_state_from_async_db(async_db, session_id).await,
        async_db,
        session_id,
        rollback,
    )
    .await?;
    rollback_delete_step(
        append_log(
            async_db,
            session_id,
            session_service::log_task_deleted(
                task_id,
                &mutation.deleted_title,
                mutation.deleted_previous_status,
            ),
            &request.actor,
        )
        .await,
        async_db,
        session_id,
        rollback,
    )
    .await
}

async fn rollback_delete_step<T>(
    step: Result<T, CliError>,
    async_db: &AsyncDaemonDb,
    session_id: &str,
    rollback: &DeleteRollback<'_>,
) -> Result<T, CliError> {
    match step {
        Ok(value) => Ok(value),
        Err(error) => {
            restore_delete_rollback(async_db, session_id, rollback, &error).await?;
            Err(error)
        }
    }
}

async fn restore_delete_rollback(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    rollback: &DeleteRollback<'_>,
    original_error: &CliError,
) -> Result<(), CliError> {
    async_db
        .save_session_state(rollback.project_id, rollback.state)
        .await
        .map_err(|restore_error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "task delete rollback save failed for session '{session_id}': {restore_error}; original error: {original_error}"
            )))
        })?;
    sync_file_state_from_async_db(async_db, session_id)
        .await
        .map_err(|restore_error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "task delete rollback file sync failed for session '{session_id}': {restore_error}; original error: {original_error}"
            )))
        })
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
    dispatch: WakeDispatch<'_>,
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
    persist_task_signal_effects(
        async_db,
        &resolved,
        session_id,
        &request.actor,
        &effects,
        None,
        dispatch,
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
    dispatch: WakeDispatch<'_>,
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
        dispatch,
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
    dispatch: WakeDispatch<'_>,
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
        dispatch,
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
    dispatch: WakeDispatch<'_>,
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
        dispatch,
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}
