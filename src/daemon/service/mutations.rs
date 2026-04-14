use super::{
    AgentRemoveRequest, CliError, LeaderTransferRequest, RoleChangeRequest, SessionDetail,
    SessionEndRequest, TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest,
    TaskDropRequest, TaskQueuePolicyRequest, TaskSource, TaskUpdateRequest,
    append_leave_signal_logs_to_db, append_task_drop_effect_logs, append_transfer_logs_to_db,
    build_log_entry, effective_project_dir, index, project_dir_for_db_session,
    refresh_signal_index_for_db, session_detail, session_not_found, session_service, slice,
    sync_after_mutation, utc_now, write_task_start_signals,
};

/// Create a task through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or task creation fails.
pub fn create_task(
    session_id: &str,
    request: &TaskCreateRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let spec = session_service::TaskSpec {
        title: &request.title,
        context: request.context.as_deref(),
        severity: request.severity,
        suggested_fix: request.suggested_fix.as_deref(),
        source: TaskSource::Manual,
        observe_issue_id: None,
    };

    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let item =
            session_service::apply_create_task(&mut state, &spec, &request.actor, &utc_now())?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_created(&spec, &item),
            Some(&request.actor),
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    let _ =
        session_service::create_task_with_source(session_id, &spec, &request.actor, project_dir)?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Assign a task through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or assignment fails.
pub fn assign_task(
    session_id: &str,
    task_id: &str,
    request: &TaskAssignRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        session_service::apply_assign_task(
            &mut state,
            task_id,
            &request.agent_id,
            &request.actor,
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_assigned(task_id, &request.agent_id),
            Some(&request.actor),
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::assign_task(
        session_id,
        task_id,
        &request.agent_id,
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Drop a task onto an extensible target through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the drop is invalid,
/// or task-start signal delivery fails.
pub fn drop_task(
    session_id: &str,
    task_id: &str,
    request: &TaskDropRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let effects = session_service::apply_drop_task(
            &mut state,
            task_id,
            &request.target,
            request.queue_policy,
            &request.actor,
            &now,
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        write_task_start_signals(&project_dir, &effects)?;
        append_task_drop_effect_logs(db, session_id, &request.actor, &effects)?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::drop_task(
        session_id,
        task_id,
        &request.target,
        request.queue_policy,
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Update a queued task's reassignment policy.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved, the task is missing,
/// or queue promotion signal delivery fails.
pub fn update_task_queue_policy(
    session_id: &str,
    task_id: &str,
    request: &TaskQueuePolicyRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let effects = session_service::apply_update_task_queue_policy(
            &mut state,
            task_id,
            request.queue_policy,
            &request.actor,
            &now,
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        write_task_start_signals(&project_dir, &effects)?;
        append_task_drop_effect_logs(db, session_id, &request.actor, &effects)?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::update_task_queue_policy(
        session_id,
        task_id,
        request.queue_policy,
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Update a task status through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the update fails.
pub fn update_task(
    session_id: &str,
    task_id: &str,
    request: &TaskUpdateRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let from_status = session_service::apply_update_task(
            &mut state,
            task_id,
            request.status,
            request.note.as_deref(),
            &request.actor,
            &now,
        )?;
        let effects =
            session_service::apply_advance_queued_tasks(&mut state, &request.actor, &now)?;
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        write_task_start_signals(&project_dir, &effects)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_status_changed(task_id, from_status, request.status),
            Some(&request.actor),
            None,
        ))?;
        append_task_drop_effect_logs(db, session_id, &request.actor, &effects)?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::update_task(
        session_id,
        task_id,
        request.status,
        request.note.as_deref(),
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Record a task checkpoint through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or checkpointing fails.
pub fn checkpoint_task(
    session_id: &str,
    task_id: &str,
    request: &TaskCheckpointRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let checkpoint = session_service::apply_record_checkpoint(
            &mut state,
            task_id,
            &request.actor,
            &request.summary,
            request.progress,
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_checkpoint(session_id, &checkpoint)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_checkpoint_recorded(
                task_id,
                &checkpoint.checkpoint_id,
                request.progress,
            ),
            Some(&request.actor),
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    let _ = session_service::record_task_checkpoint(
        session_id,
        task_id,
        &request.actor,
        &request.summary,
        request.progress,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Change an agent role through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the role change fails.
pub fn change_role(
    session_id: &str,
    agent_id: &str,
    request: &RoleChangeRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let from_role = session_service::apply_assign_role(
            &mut state,
            agent_id,
            request.role,
            &request.actor,
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_role_changed(agent_id, from_role, request.role),
            Some(&request.actor),
            request.reason.as_deref(),
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::assign_role(
        session_id,
        agent_id,
        request.role,
        request.reason.as_deref(),
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Remove an agent through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the removal fails.
pub fn remove_agent(
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let leave_signal = session_service::prepare_remove_agent_leave_signal(
            &state,
            agent_id,
            &request.actor,
            &now,
        )?;
        if let Some(ref signal) = leave_signal {
            session_service::write_prepared_leave_signals(
                &project_dir,
                slice::from_ref(signal),
                "remove agent",
            )?;
        }
        session_service::apply_remove_agent(&mut state, agent_id, &request.actor, &now)?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        if let Some(ref signal) = leave_signal {
            append_leave_signal_logs_to_db(
                db,
                session_id,
                &request.actor,
                slice::from_ref(signal),
            )?;
        }
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_removed(agent_id),
            Some(&request.actor),
            None,
        ))?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::remove_agent(session_id, agent_id, &request.actor, project_dir)?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Transfer session leadership through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub fn transfer_leader(
    session_id: &str,
    request: &LeaderTransferRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let plan = session_service::apply_transfer_leader(
            &mut state,
            &request.new_leader_id,
            &request.actor,
            request.reason.as_deref(),
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        append_transfer_logs_to_db(db, session_id, &request.actor, &plan)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::transfer_leader(
        session_id,
        &request.new_leader_id,
        request.reason.as_deref(),
        &request.actor,
        project_dir,
    )?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// End a session through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or ending fails.
pub fn end_session(
    session_id: &str,
    request: &SessionEndRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let leave_signals =
            session_service::prepare_end_session_leave_signals(&state, &request.actor, &now)?;
        session_service::write_prepared_leave_signals(&project_dir, &leave_signals, "end session")?;
        session_service::apply_end_session(&mut state, &request.actor, &now)?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.mark_session_inactive(session_id)?;
        append_leave_signal_logs_to_db(db, session_id, &request.actor, &leave_signals)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_session_ended(),
            Some(&request.actor),
            None,
        ))?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail(session_id, Some(db));
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::end_session(session_id, &request.actor, project_dir)?;
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}
