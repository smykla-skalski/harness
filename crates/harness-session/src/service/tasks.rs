use super::{
    CliError, CliErrorKind, Path, TaskCheckpoint, TaskQueuePolicy, TaskSeverity, TaskSource,
    TaskSpec, TaskStatus, WorkItem, append_task_drop_effect_logs, apply_advance_queued_tasks,
    apply_assign_task, apply_create_task, apply_delete_task, apply_drop_task,
    apply_record_checkpoint, apply_update_task, apply_update_task_queue_policy,
    daemon_client_error, ensure_valid_progress, load_state_or_err, log_checkpoint_recorded,
    log_task_assigned, log_task_created, log_task_deleted, log_task_status_changed,
    reconcile_expired_pending_signals, refresh_session, sort_session_tasks, started_task_signals,
    storage, utc_now, wire, write_prepared_task_start_signals,
};
use harness_daemon_client::DaemonClient;
use harness_kernel::io::validate_safe_segment;

/// Create a work item in the session.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or on storage failures.
pub fn create_task(
    session_id: &str,
    title: &str,
    context: Option<&str>,
    severity: TaskSeverity,
    actor_id: &str,
    project_dir: &Path,
) -> Result<WorkItem, CliError> {
    let spec = TaskSpec {
        title,
        context,
        severity,
        suggested_fix: None,
        source: TaskSource::Manual,
        observe_issue_id: None,
    };
    create_task_with_source_local(session_id, &spec, actor_id, project_dir)
}

/// Create a task with explicit source metadata, applying the mutation to
/// local storage unconditionally.
///
/// Domain-only half of the former fused function: `daemon::service::mutations::tasks::create_task`
/// calls this directly as its own no-database-row fallback, from inside the
/// daemon's own async runtime, so it must never try to dial a live daemon
/// itself. The network wrapper lives at
/// `harness::session::service::create_task_with_source` in the root crate.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or on storage failures.
pub fn create_task_with_source_local(
    session_id: &str,
    spec: &TaskSpec<'_>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<WorkItem, CliError> {
    let now = utc_now();
    let mut created_item = None;
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        created_item = Some(apply_create_task(state, spec, actor_id, &now)?);
        Ok(())
    })?;

    let item = created_item.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task creation did not persist state".to_string(),
        ))
    })?;
    storage::append_log_entry(&layout, log_task_created(spec, &item), Some(actor_id), None)?;

    Ok(item)
}

/// Assign a work item to an agent (leader only), applying the mutation to
/// local storage unconditionally.
///
/// Domain-only half of the former fused function: `daemon::service::mutations::tasks::assign_task`
/// calls this directly as its own no-database-row fallback, from inside the
/// daemon's own async runtime, so it must never try to dial a live daemon
/// itself. The network wrapper lives at `harness::session::service::assign_task`
/// in the root crate.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or task/agent not found.
pub fn assign_task_local(
    session_id: &str,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let mut effects = Vec::new();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        effects = apply_assign_task(state, task_id, agent_id, actor_id, &now)?;
        Ok(())
    })?;

    let start_signals = started_task_signals(&effects);
    write_prepared_task_start_signals(project_dir, &start_signals)?;
    storage::append_log_entry(
        &layout,
        log_task_assigned(task_id, agent_id),
        Some(actor_id),
        None,
    )?;
    append_task_drop_effect_logs(project_dir, session_id, actor_id, &effects)?;

    Ok(())
}

/// Drop a work item onto a session target, applying the mutation to local
/// storage unconditionally.
///
/// Domain-only half of the former fused function: `daemon::service::mutations::tasks::drop_task`
/// calls this directly as its own no-database-row fallback, from inside the
/// daemon's own async runtime, so it must never try to dial a live daemon
/// itself. The network wrapper lives at `harness::session::service::drop_task`
/// in the root crate.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, the target is invalid,
/// or signal delivery setup fails for an immediately-started task.
pub fn drop_task_local(
    session_id: &str,
    task_id: &str,
    target: &wire::TaskDropTarget,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let mut effects = Vec::new();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;
    storage::update_state(&layout, |state| {
        effects = apply_drop_task(state, task_id, target, queue_policy, actor_id, &now)?;
        Ok(())
    })?;

    let start_signals = started_task_signals(&effects);
    write_prepared_task_start_signals(project_dir, &start_signals)?;
    append_task_drop_effect_logs(project_dir, session_id, actor_id, &effects)?;
    Ok(())
}

/// Change a queued task's reassignment policy.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or queue promotion signal
/// delivery fails.
pub fn update_task_queue_policy(
    session_id: &str,
    task_id: &str,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let mut effects = Vec::new();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;
    storage::update_state(&layout, |state| {
        effects = apply_update_task_queue_policy(state, task_id, queue_policy, actor_id, &now)?;
        Ok(())
    })?;

    let start_signals = started_task_signals(&effects);
    write_prepared_task_start_signals(project_dir, &start_signals)?;
    append_task_drop_effect_logs(project_dir, session_id, actor_id, &effects)?;
    Ok(())
}

/// List work items, optionally filtered by status.
///
/// # Errors
/// Returns `CliError` if the session is not found.
pub fn list_tasks(
    session_id: &str,
    status_filter: Option<TaskStatus>,
    project_dir: &Path,
) -> Result<Vec<WorkItem>, CliError> {
    // No daemon-side caller reaches this directly, so it needs no
    // tokio-runtime guard.
    if let Some(client) = DaemonClient::try_connect() {
        validate_safe_segment(session_id)?;
        let detail: wire::SessionDetail = client
            .get(&format!("/v1/sessions/{session_id}"), &[])
            .map_err(|error| daemon_client_error("get session detail", &error))?;
        let mut items: Vec<WorkItem> = detail
            .tasks
            .into_iter()
            .filter(|task| status_filter.is_none_or(|status| task.status == status))
            .collect();
        sort_session_tasks(&mut items);
        return Ok(items);
    }

    reconcile_expired_pending_signals(session_id, project_dir)?;
    let state = load_state_or_err(session_id, project_dir)?;
    let mut items: Vec<WorkItem> = state
        .tasks
        .into_values()
        .filter(|task| !task.is_deleted())
        .filter(|task| status_filter.is_none_or(|status| task.status == status))
        .collect();
    sort_session_tasks(&mut items);
    Ok(items)
}

/// Delete a work item from active task views while preserving history,
/// applying the mutation to local storage unconditionally.
///
/// Domain-only half of the former fused function: `daemon::service::mutations::tasks::delete_task`
/// calls this directly as its own no-database-row fallback, from inside the
/// daemon's own async runtime, so it must never try to dial a live daemon
/// itself. The network wrapper lives at `harness::session::service::delete_task`
/// in the root crate.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the task is not found.
pub fn delete_task_local(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let mut deleted = None;
    let mut effects = Vec::new();
    let mut rollback_state = None;
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        rollback_state = Some(state.clone());
        deleted = Some(apply_delete_task(state, task_id, actor_id, &now)?);
        effects = apply_advance_queued_tasks(state, actor_id, &now)?;
        refresh_session(state, &now);
        Ok(())
    })?;

    let deleted = deleted.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task deletion did not persist state".to_string(),
        ))
    })?;
    let delete_transition = log_task_deleted(task_id, &deleted.title, deleted.previous_status);
    if let Err(error) = storage::append_log_entry(&layout, delete_transition, Some(actor_id), None)
    {
        let rollback = rollback_state.ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(
                "task delete rollback state missing".to_string(),
            ))
        })?;
        if let Err(restore_error) = storage::save_state(&layout, &rollback) {
            return Err(CliError::from(CliErrorKind::workflow_io(format!(
                "task delete audit append failed and rollback could not be restored: {restore_error}; original error: {error}"
            ))));
        }
        return Err(error);
    }

    let start_signals = started_task_signals(&effects);
    write_prepared_task_start_signals(project_dir, &start_signals)?;
    append_task_drop_effect_logs(project_dir, session_id, actor_id, &effects)?;

    Ok(())
}

/// Update a work item's status, applying the mutation to local storage
/// unconditionally.
///
/// Domain-only half of the former fused function: `daemon::service::mutations::tasks::update_task`
/// calls this directly as its own no-database-row fallback, from inside the
/// daemon's own async runtime, so it must never try to dial a live daemon
/// itself. The network wrapper lives at `harness::session::service::update_task`
/// in the root crate.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the task is not found.
pub fn update_task_local(
    session_id: &str,
    task_id: &str,
    status: TaskStatus,
    note: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let mut from_status = TaskStatus::Open;
    let mut effects = Vec::new();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        from_status = apply_update_task(state, task_id, status, note, actor_id, &now)?;
        effects = apply_advance_queued_tasks(state, actor_id, &now)?;
        refresh_session(state, &now);
        Ok(())
    })?;

    let start_signals = started_task_signals(&effects);
    write_prepared_task_start_signals(project_dir, &start_signals)?;
    storage::append_log_entry(
        &layout,
        log_task_status_changed(task_id, from_status, status),
        Some(actor_id),
        None,
    )?;
    append_task_drop_effect_logs(project_dir, session_id, actor_id, &effects)?;

    Ok(())
}

/// Record an append-only task checkpoint, applying the mutation to local
/// storage unconditionally.
///
/// Domain-only half of the former fused function: `daemon::service::mutations::tasks::checkpoint_task`
/// calls this directly as its own no-database-row fallback, from inside the
/// daemon's own async runtime, so it must never try to dial a live daemon
/// itself. The network wrapper lives at
/// `harness::session::service::record_task_checkpoint` in the root crate.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the task is not found.
pub fn record_task_checkpoint_local(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    summary: &str,
    progress: u8,
    project_dir: &Path,
) -> Result<TaskCheckpoint, CliError> {
    ensure_valid_progress(progress)?;

    let now = utc_now();
    let mut checkpoint = None;
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        checkpoint = Some(apply_record_checkpoint(
            state, task_id, actor_id, summary, progress, &now,
        )?);
        Ok(())
    })?;

    let checkpoint = checkpoint.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task checkpoint did not persist state".to_string(),
        ))
    })?;
    storage::append_task_checkpoint(&layout, task_id, &checkpoint)?;
    storage::append_log_entry(
        &layout,
        log_checkpoint_recorded(task_id, &checkpoint.checkpoint_id, progress),
        Some(actor_id),
        None,
    )?;
    Ok(checkpoint)
}
