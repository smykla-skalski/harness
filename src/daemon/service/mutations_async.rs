use std::path::Path;

use crate::daemon::index::ResolvedSession;

use super::{
    AgentRemoveRequest, CliError, LeaderTransferRequest, RoleChangeRequest, SessionDetail,
    SessionEndRequest, SessionTransition, TaskAssignRequest, TaskCheckpointRequest,
    TaskCreateRequest, TaskDropRequest, TaskQueuePolicyRequest, TaskSource, TaskUpdateRequest,
    append_transfer_logs_to_async_db, build_log_entry, effective_project_dir,
    session_detail_from_async_daemon_db, session_not_found, session_service, slice, snapshot,
    sync_file_state_for_resolved, sync_file_state_from_async_db, task_drop_effect_signal_records,
    utc_now, write_task_start_signals,
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

async fn refresh_signal_index_for_resolved(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
) -> Result<(), CliError> {
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    async_db
        .sync_signal_index(&resolved.state.session_id, &signals)
        .await
}

async fn append_task_drop_effect_logs_async(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    actor_id: &str,
    effects: &[session_service::TaskDropEffect],
) -> Result<(), CliError> {
    for effect in effects {
        let transition = match effect {
            session_service::TaskDropEffect::Started(signal) => session_service::log_signal_sent(
                &signal.signal.signal_id,
                &signal.agent_id,
                &signal.signal.command,
            ),
            session_service::TaskDropEffect::Queued { task_id, agent_id } => {
                session_service::log_task_queued(task_id, agent_id)
            }
        };
        async_db
            .append_log_entry(&build_log_entry(
                session_id,
                transition,
                Some(actor_id),
                None,
            ))
            .await?;
    }
    Ok(())
}

async fn append_leave_signal_logs_async(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    actor_id: &str,
    signals: &[session_service::LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        async_db
            .append_log_entry(&build_log_entry(
                session_id,
                session_service::log_signal_sent(
                    &signal.signal.signal_id,
                    &signal.agent_id,
                    &signal.signal.command,
                ),
                Some(actor_id),
                None,
            ))
            .await?;
    }
    Ok(())
}

async fn persist_task_signal_effects(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
    session_id: &str,
    actor_id: &str,
    effects: &[session_service::TaskDropEffect],
    extra_transition: Option<SessionTransition>,
) -> Result<(), CliError> {
    let project_dir = effective_project_dir(resolved).to_path_buf();
    sync_file_state_for_resolved(resolved)?;
    write_task_start_signals(&project_dir, effects)?;
    if let Some(transition) = extra_transition {
        async_db
            .append_log_entry(&build_log_entry(
                session_id,
                transition,
                Some(actor_id),
                None,
            ))
            .await?;
    }
    append_task_drop_effect_logs_async(async_db, session_id, actor_id, effects).await?;
    async_db
        .merge_signal_records(
            session_id,
            &task_drop_effect_signal_records(session_id, effects),
        )
        .await?;
    bump_session(async_db, session_id).await
}

async fn persist_leave_signal_mutation(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &ResolvedSession,
    session_id: &str,
    actor_id: &str,
    leave_signals: &[session_service::LeaveSignalRecord],
    transition: SessionTransition,
) -> Result<(), CliError> {
    sync_file_state_for_resolved(resolved)?;
    append_leave_signal_logs_async(async_db, session_id, actor_id, leave_signals).await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            transition,
            Some(actor_id),
            None,
        ))
        .await?;
    refresh_signal_index_for_resolved(async_db, resolved).await?;
    bump_session(async_db, session_id).await
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
    let now = utc_now();
    let item = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_create_task(state, &spec, &request.actor, &now)
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_created(&spec, &item),
            Some(&request.actor),
            None,
        ))
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
    async_db: &super::db::AsyncDaemonDb,
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
    let log = Some(session_service::log_task_assigned(task_id, &request.agent_id));
    persist_task_signal_effects(async_db, &resolved, session_id, &request.actor, &effects, log)
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
    async_db: &super::db::AsyncDaemonDb,
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
    async_db: &super::db::AsyncDaemonDb,
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
    async_db: &super::db::AsyncDaemonDb,
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
    async_db: &super::db::AsyncDaemonDb,
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
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the removal fails.
pub(crate) async fn remove_agent_async(
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
    async_db: &super::db::AsyncDaemonDb,
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

/// Transfer session leadership through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub(crate) async fn transfer_leader_async(
    session_id: &str,
    request: &LeaderTransferRequest,
    async_db: &super::db::AsyncDaemonDb,
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
    async_db: &super::db::AsyncDaemonDb,
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
