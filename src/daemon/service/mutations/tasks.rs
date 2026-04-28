use super::super::{
    AgentTuiManagerHandle, CliError, SessionDetail, TaskAssignRequest, TaskCheckpointRequest,
    TaskCreateRequest, TaskDropRequest, TaskQueuePolicyRequest, TaskSource, TaskUpdateRequest,
    append_task_drop_effect_logs, build_log_entry, effective_project_dir, index,
    project_dir_for_db_session, session_detail, session_detail_from_daemon_db, session_not_found,
    session_service, task_drop_effect_signal_records, try_wake_started_workers, utc_now,
    write_task_start_signals,
};

/// Create a task through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or task creation fails.
pub fn create_task(
    session_id: &str,
    request: &TaskCreateRequest,
    db: Option<&super::super::db::DaemonDb>,
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
        return session_detail_from_daemon_db(session_id, db);
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    let _ =
        session_service::create_task_with_source(session_id, &spec, &request.actor, project_dir)?;
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
    db: Option<&super::super::db::DaemonDb>,
    agent_tui_manager: Option<&AgentTuiManagerHandle>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let effects = session_service::apply_assign_task(
            &mut state,
            task_id,
            &request.agent_id,
            &request.actor,
            &now,
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        write_task_start_signals(&project_dir, &effects)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_assigned(task_id, &request.agent_id),
            Some(&request.actor),
            None,
        ))?;
        append_task_drop_effect_logs(db, session_id, &request.actor, &effects)?;
        db.merge_signal_records(
            session_id,
            &task_drop_effect_signal_records(session_id, &effects),
        )?;
        try_wake_started_workers(
            &state,
            &effects,
            session_id,
            &project_dir,
            Some(db),
            agent_tui_manager,
        );
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
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
    db: Option<&super::super::db::DaemonDb>,
    agent_tui_manager: Option<&AgentTuiManagerHandle>,
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
        db.merge_signal_records(
            session_id,
            &task_drop_effect_signal_records(session_id, &effects),
        )?;
        try_wake_started_workers(
            &state,
            &effects,
            session_id,
            &project_dir,
            Some(db),
            agent_tui_manager,
        );
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
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
    db: Option<&super::super::db::DaemonDb>,
    agent_tui_manager: Option<&AgentTuiManagerHandle>,
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
        db.merge_signal_records(
            session_id,
            &task_drop_effect_signal_records(session_id, &effects),
        )?;
        try_wake_started_workers(
            &state,
            &effects,
            session_id,
            &project_dir,
            Some(db),
            agent_tui_manager,
        );
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
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
    db: Option<&super::super::db::DaemonDb>,
    agent_tui_manager: Option<&AgentTuiManagerHandle>,
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
        db.merge_signal_records(
            session_id,
            &task_drop_effect_signal_records(session_id, &effects),
        )?;
        try_wake_started_workers(
            &state,
            &effects,
            session_id,
            &project_dir,
            Some(db),
            agent_tui_manager,
        );
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
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
    db: Option<&super::super::db::DaemonDb>,
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
        return session_detail_from_daemon_db(session_id, db);
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
    session_detail(session_id, db)
}
