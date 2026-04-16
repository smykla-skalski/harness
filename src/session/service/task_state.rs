use super::{
    CliError, CliErrorKind, DeliveryConfig, Duration, SessionAction, SessionState, Signal,
    SignalPayload, SignalPriority, TaskCheckpoint, TaskCheckpointSummary, TaskDropEffect, TaskNote,
    TaskQueuePolicy, TaskSpec, TaskStatus, Utc, Value, WorkItem, agent_status_label,
    apply_drop_task_on_agent, clear_agent_current_task, free_worker_ids, generate_checkpoint_id,
    generate_signal_id, next_task_id, protocol, refresh_session, require_active,
    require_active_worker_target_agent, require_permission, start_next_locked_task_for_worker,
    start_task_for_agent, task_not_found, touch_agent,
};

/// Create a work item. Returns the new `WorkItem`.
pub(crate) fn apply_create_task(
    state: &mut SessionState,
    spec: &TaskSpec<'_>,
    actor_id: &str,
    now: &str,
) -> Result<WorkItem, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::CreateTask)?;

    let task_id = next_task_id(&state.tasks);
    let item = WorkItem {
        task_id: task_id.clone(),
        title: spec.title.to_string(),
        context: spec.context.map(ToString::to_string),
        severity: spec.severity,
        status: TaskStatus::Open,
        assigned_to: None,
        queue_policy: TaskQueuePolicy::Locked,
        queued_at: None,
        created_at: now.to_string(),
        updated_at: now.to_string(),
        created_by: Some(actor_id.to_string()),
        notes: Vec::new(),
        suggested_fix: spec.suggested_fix.map(ToString::to_string),
        source: spec.source,
        observe_issue_id: spec.observe_issue_id.map(ToString::to_string),
        blocked_reason: None,
        completed_at: None,
        checkpoint_summary: None,
    };
    state.tasks.insert(task_id, item.clone());
    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(item)
}

/// Assign a task to an agent.
pub(crate) fn apply_assign_task(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::AssignTask)?;
    require_active_worker_target_agent(state, agent_id)?;

    let previous_assignee = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?
        .assigned_to
        .clone();
    if let Some(previous_assignee) = previous_assignee.as_deref() {
        clear_agent_current_task(state, previous_assignee, task_id, now);
    }

    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.assigned_to = Some(agent_id.to_string());
    task.status = TaskStatus::Open;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.updated_at = now.to_string();
    task.blocked_reason = None;
    task.completed_at = None;

    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.current_task_id = Some(task_id.to_string());
        agent.updated_at = now.to_string();
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(())
}

/// Drop a task onto an extensible session target. The first target action is
/// worker assignment: start immediately when the worker is free, otherwise
/// queue against the selected worker.
pub(crate) fn apply_drop_task(
    state: &mut SessionState,
    task_id: &str,
    target: &protocol::TaskDropTarget,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::AssignTask)?;

    match target {
        protocol::TaskDropTarget::Agent { agent_id } => {
            apply_drop_task_on_agent(state, task_id, agent_id, queue_policy, actor_id, now)
        }
    }
}

pub(crate) fn apply_update_task_queue_policy(
    state: &mut SessionState,
    task_id: &str,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::AssignTask)?;
    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.queue_policy = queue_policy;
    task.updated_at = now.to_string();
    touch_agent(state, actor_id, now);
    let effects = apply_advance_queued_tasks(state, actor_id, now)?;
    refresh_session(state, now);
    Ok(effects)
}

pub(crate) fn apply_advance_queued_tasks(
    state: &mut SessionState,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    let mut effects = Vec::new();
    let mut free_workers = free_worker_ids(state);
    free_workers.sort_unstable();

    for worker_id in free_workers.clone() {
        if start_next_locked_task_for_worker(state, &worker_id, actor_id, now, &mut effects)? {
            free_workers.retain(|candidate| candidate != &worker_id);
        }
    }

    let mut reassignable_tasks: Vec<_> = state
        .tasks
        .values()
        .filter(|task| {
            task.status == TaskStatus::Open
                && task.queued_at.is_some()
                && task.assigned_to.is_some()
                && task.queue_policy == TaskQueuePolicy::ReassignWhenFree
        })
        .map(|task| {
            (
                task.queued_at.clone().unwrap_or_default(),
                task.task_id.clone(),
            )
        })
        .collect();
    reassignable_tasks.sort_unstable();

    for (_, task_id) in reassignable_tasks {
        let Some(worker_id) = free_workers.first().cloned() else {
            break;
        };
        start_task_for_agent(state, &task_id, &worker_id, actor_id, now, &mut effects)?;
        free_workers.remove(0);
    }

    Ok(effects)
}

/// Update a task's status. Returns the previous status.
pub(crate) fn apply_update_task(
    state: &mut SessionState,
    task_id: &str,
    status: TaskStatus,
    note: Option<&str>,
    actor_id: &str,
    now: &str,
) -> Result<TaskStatus, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;

    let assigned_to = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?
        .assigned_to
        .clone();
    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;

    let from_status = task.status;
    task.status = status;
    if status != TaskStatus::Open {
        task.queued_at = None;
    }
    task.updated_at = now.to_string();
    if let Some(text) = note {
        task.notes.push(TaskNote {
            timestamp: now.to_string(),
            agent_id: Some(actor_id.to_string()),
            text: text.to_string(),
        });
    }

    match status {
        TaskStatus::Done => {
            task.completed_at = Some(now.to_string());
            task.blocked_reason = None;
        }
        TaskStatus::Blocked => {
            task.blocked_reason = note.map(ToString::to_string);
            task.completed_at = None;
        }
        TaskStatus::Open | TaskStatus::InProgress | TaskStatus::InReview => {
            task.blocked_reason = None;
            task.completed_at = None;
        }
    }

    if let Some(assigned_to) = assigned_to.as_deref() {
        if status == TaskStatus::InProgress {
            if let Some(agent) = state.agents.get_mut(assigned_to) {
                agent.current_task_id = Some(task_id.to_string());
                agent.updated_at = now.to_string();
                agent.last_activity_at = Some(now.to_string());
            }
        } else {
            clear_agent_current_task(state, assigned_to, task_id, now);
        }
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(from_status)
}

/// Record a task checkpoint in state. Returns the `TaskCheckpoint`.
pub(crate) fn apply_record_checkpoint(
    state: &mut SessionState,
    task_id: &str,
    actor_id: &str,
    summary: &str,
    progress: u8,
    now: &str,
) -> Result<TaskCheckpoint, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;

    let assigned_to = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?
        .assigned_to
        .clone();
    let created = TaskCheckpoint {
        checkpoint_id: generate_checkpoint_id(task_id),
        task_id: task_id.to_string(),
        recorded_at: now.to_string(),
        actor_id: Some(actor_id.to_string()),
        summary: summary.to_string(),
        progress,
    };

    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    if task.status == TaskStatus::Open {
        task.status = TaskStatus::InProgress;
    }
    task.queued_at = None;
    task.updated_at = now.to_string();
    task.checkpoint_summary = Some(TaskCheckpointSummary::from(&created));

    if let Some(assigned_to) = assigned_to.as_deref()
        && let Some(agent) = state.agents.get_mut(assigned_to)
    {
        agent.current_task_id = Some(task_id.to_string());
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(created)
}

/// Validate and extract signal target info from state. Returns
/// `(runtime_name, target_agent_session_id)`.
pub(crate) fn apply_send_signal_state(
    state: &mut SessionState,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<(String, Option<String>), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::SendSignal)?;
    let target_agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if !target_agent.status.is_alive() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is {}",
            agent_status_label(target_agent.status)
        ))
        .into());
    }

    let runtime_name = target_agent.runtime.clone();
    let target_agent_session_id = target_agent.agent_session_id.clone();
    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok((runtime_name, target_agent_session_id))
}

/// Build a signal payload without writing it to disk. Used by the daemon
/// handler which writes to `SQLite` first, then writes the signal file.
pub(crate) fn build_signal(
    actor_id: &str,
    command: &str,
    message: &str,
    action_hint: Option<&str>,
    session_id: &str,
    agent_id: &str,
    now: &str,
) -> Signal {
    Signal {
        signal_id: generate_signal_id(),
        version: 1,
        created_at: now.to_string(),
        expires_at: (Utc::now() + Duration::minutes(15))
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string(),
        source_agent: actor_id.to_string(),
        command: command.to_string(),
        priority: SignalPriority::Normal,
        payload: SignalPayload {
            message: message.to_string(),
            action_hint: action_hint.map(ToString::to_string),
            related_files: Vec::new(),
            metadata: Value::Null,
        },
        delivery: DeliveryConfig {
            max_retries: 3,
            retry_count: 0,
            idempotency_key: Some(format!(
                "{}:{}:{}",
                session_id,
                agent_id,
                action_hint.unwrap_or(command)
            )),
        },
    }
}

// ---------------------------------------------------------------------------
// Log-entry builders (shared between file and daemon paths)
// ---------------------------------------------------------------------------
