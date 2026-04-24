use super::{
    CliError, CliErrorKind, DaemonClient, Path, TaskCheckpoint, TaskQueuePolicy, TaskSeverity,
    TaskSource, TaskSpec, TaskStatus, WorkItem, append_task_drop_effect_logs,
    apply_advance_queued_tasks, apply_assign_task, apply_create_task, apply_drop_task,
    apply_record_checkpoint, apply_submit_for_review, apply_update_task,
    apply_update_task_queue_policy, ensure_valid_progress, generate_checkpoint_id,
    load_state_or_err, log_checkpoint_recorded, log_task_assigned, log_task_created,
    log_task_status_changed, protocol, reconcile_expired_pending_signals, refresh_session,
    sort_session_tasks, started_task_signals, storage, utc_now,
    write_prepared_task_start_signals,
};

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
    create_task_with_source(session_id, &spec, actor_id, project_dir)
}

/// Create a task with explicit source metadata.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or on storage failures.
pub fn create_task_with_source(
    session_id: &str,
    spec: &TaskSpec<'_>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<WorkItem, CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.create_task(
            session_id,
            &protocol::TaskCreateRequest {
                actor: actor_id.to_string(),
                title: spec.title.to_string(),
                context: spec.context.map(ToString::to_string),
                severity: spec.severity,
                suggested_fix: spec.suggested_fix.map(ToString::to_string),
            },
        )?;
        let created = detail.tasks.into_iter().max_by(|left, right| {
            left.created_at
                .cmp(&right.created_at)
                .then_with(|| left.updated_at.cmp(&right.updated_at))
                .then_with(|| left.task_id.cmp(&right.task_id))
        });
        return created.ok_or_else(|| {
            CliErrorKind::workflow_io("daemon created task but returned empty task list").into()
        });
    }

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

/// Assign a work item to an agent (leader only).
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or task/agent not found.
pub fn assign_task(
    session_id: &str,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.assign_task(
            session_id,
            task_id,
            &protocol::TaskAssignRequest {
                actor: actor_id.to_string(),
                agent_id: agent_id.to_string(),
            },
        )?;
        return Ok(());
    }

    let now = utc_now();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        apply_assign_task(state, task_id, agent_id, actor_id, &now)
    })?;

    storage::append_log_entry(
        &layout,
        log_task_assigned(task_id, agent_id),
        Some(actor_id),
        None,
    )?;

    Ok(())
}

/// Drop a work item onto a session target.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission, the target is invalid,
/// or signal delivery setup fails for an immediately-started task.
pub fn drop_task(
    session_id: &str,
    task_id: &str,
    target: &protocol::TaskDropTarget,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.drop_task(
            session_id,
            task_id,
            &protocol::TaskDropRequest {
                actor: actor_id.to_string(),
                target: target.clone(),
                queue_policy,
            },
        )?;
        return Ok(());
    }

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
    if let Some(client) = DaemonClient::try_connect() {
        let detail = client.get_session_detail(session_id)?;
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
        .filter(|task| status_filter.is_none_or(|status| task.status == status))
        .collect();
    sort_session_tasks(&mut items);
    Ok(items)
}

/// Update a work item's status.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the task is not found.
pub fn update_task(
    session_id: &str,
    task_id: &str,
    status: TaskStatus,
    note: Option<&str>,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.update_task(
            session_id,
            task_id,
            &protocol::TaskUpdateRequest {
                actor: actor_id.to_string(),
                status,
                note: note.map(ToString::to_string),
            },
        )?;
        return Ok(());
    }

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

/// Submit a task for review.
///
/// Transitions the task from `InProgress` to `AwaitingReview`, unassigns it,
/// and flips the submitting worker's agent status to
/// `AgentStatus::AwaitingReview`.
///
/// # Errors
/// Returns `CliError` if the session is not active, the task is not
/// `InProgress`, the task is not assigned to the actor, or storage fails.
pub fn submit_for_review(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    summary: Option<&str>,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        apply_submit_for_review(state, task_id, actor_id, summary, &now)
    })?;

    storage::append_log_entry(
        &layout,
        log_task_status_changed(task_id, TaskStatus::InProgress, TaskStatus::AwaitingReview),
        Some(actor_id),
        None,
    )?;
    Ok(())
}

/// Record an append-only task checkpoint.
///
/// # Errors
/// Returns `CliError` if the caller lacks permission or the task is not found.
pub fn record_task_checkpoint(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    summary: &str,
    progress: u8,
    project_dir: &Path,
) -> Result<TaskCheckpoint, CliError> {
    ensure_valid_progress(progress)?;

    if let Some(client) = DaemonClient::try_connect() {
        let _ = client.checkpoint_task(
            session_id,
            task_id,
            &protocol::TaskCheckpointRequest {
                actor: actor_id.to_string(),
                summary: summary.to_string(),
                progress,
            },
        )?;
        return Ok(TaskCheckpoint {
            checkpoint_id: generate_checkpoint_id(task_id),
            task_id: task_id.to_string(),
            recorded_at: utc_now(),
            actor_id: Some(actor_id.to_string()),
            summary: summary.to_string(),
            progress,
        });
    }

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
