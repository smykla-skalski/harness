use super::{
    CliError, CliErrorKind, START_TASK_SIGNAL_COMMAND, SessionRole, SessionState, TaskDropEffect,
    TaskQueuePolicy, TaskStartSignalRecord, TaskStatus, WorkItem, apply_advance_queued_tasks,
    build_signal, clear_agent_current_task, refresh_session,
    reject_generic_mutation_on_review_state, require_active_worker_target_agent, task_not_found,
    task_status_label, touch_agent,
};

/// Apply a task drop onto a worker agent.
///
/// State ownership: this is the single canonical mutator that moves a task
/// onto a worker. It always clears the prior `current_task_id` pointer that
/// referenced the dropped task (regardless of whether the previous assignee
/// equals the new target), runs `is_worker_free` to decide between the
/// Started and Queued branches, and writes effects that downstream callers
/// turn into signal files and audit log entries.
///
/// Signal delivery contract: producing a `TaskDropEffect::Started` means a
/// task-start signal record is appended to the effects vector but not
/// delivered. Callers (sync file path, daemon sync DB, daemon async DB) own
/// fanning out the effects to the file system, the signal index, and the
/// audit log via `write_task_start_signals` + `merge_signal_records`.
/// Worker wake (TUI prompt) is the caller's responsibility too; the assign
/// and drop paths do not yet wire `attempt_active_signal_delivery`, so a
/// managed-TUI worker still wakes via the next signal-dir scan rather than
/// an immediate kick.
pub(crate) fn apply_drop_task_on_agent(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    require_active_worker_target_agent(state, agent_id)?;

    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    reject_generic_mutation_on_review_state(task_id, task, "reassigned via drop")?;

    let previous_assignee = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?
        .assigned_to
        .clone();
    if let Some(previous_assignee) = previous_assignee.as_deref() {
        // Clear the current_task_id pointer regardless of whether the previous
        // assignee was a different agent or the same one we are dropping onto:
        // the pointer reflects "this task is owned" and the drop is the
        // canonical way to (re-)deliver it. Leaving the pointer set when the
        // target equals the previous assignee makes is_worker_free below treat
        // the agent as busy with this same task, which queues the task behind
        // itself instead of starting it.
        clear_agent_current_task(state, previous_assignee, task_id, now);
    }

    let mut effects = Vec::new();
    if is_worker_free(state, agent_id) {
        start_task_for_agent(state, task_id, agent_id, actor_id, now, &mut effects)?;
    } else {
        queue_task_for_agent(state, task_id, agent_id, queue_policy, now)?;
        effects.push(TaskDropEffect::Queued {
            task_id: task_id.to_string(),
            agent_id: agent_id.to_string(),
        });
    }

    touch_agent(state, actor_id, now);
    let advanced = apply_advance_queued_tasks(state, actor_id, now)?;
    effects.extend(advanced);
    refresh_session(state, now);
    Ok(effects)
}

pub(crate) fn queue_task_for_agent(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    queue_policy: TaskQueuePolicy,
    now: &str,
) -> Result<(), CliError> {
    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    reject_generic_mutation_on_review_state(task_id, task, "queued")?;
    if task.status != TaskStatus::Open {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' is {}, not open",
            task_status_label(task.status)
        ))
        .into());
    }
    task.assigned_to = Some(agent_id.to_string());
    task.queue_policy = queue_policy;
    task.queued_at = Some(now.to_string());
    task.updated_at = now.to_string();
    Ok(())
}

pub(crate) fn start_task_for_agent(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    now: &str,
    effects: &mut Vec<TaskDropEffect>,
) -> Result<(), CliError> {
    require_active_worker_target_agent(state, agent_id)?;
    if !is_worker_free(state, agent_id) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is not free"
        ))
        .into());
    }

    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    reject_generic_mutation_on_review_state(task_id, task, "started")?;

    let previous_assignee = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?
        .assigned_to
        .clone();
    if let Some(previous_assignee) = previous_assignee.as_deref()
        && previous_assignee != agent_id
    {
        clear_agent_current_task(state, previous_assignee, task_id, now);
    }

    let signal = build_task_start_signal_record(state, task_id, agent_id, actor_id, now)?;
    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.assigned_to = Some(agent_id.to_string());
    task.status = TaskStatus::Open;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.blocked_reason = None;
    task.completed_at = None;
    task.updated_at = now.to_string();

    if let Some(agent) = state.agents.get_mut(agent_id) {
        // Eagerly mark the agent as occupied by this task so a subsequent
        // drop_task on a different task is queued and a re-drop of this same
        // task is detected by the cleared-pointer path above. The signal-ack
        // handler reaffirms this pointer when the worker actually starts.
        agent.current_task_id = Some(task_id.to_string());
        agent.updated_at = now.to_string();
    }

    effects.push(TaskDropEffect::Started(Box::new(signal)));
    Ok(())
}

pub(crate) fn build_task_start_signal_record(
    state: &SessionState,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<TaskStartSignalRecord, CliError> {
    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    let message = task_start_message(task);
    let action_hint = task_start_action_hint(task_id);
    let signal = build_signal(
        actor_id,
        START_TASK_SIGNAL_COMMAND,
        &message,
        Some(&action_hint),
        &state.session_id,
        agent_id,
        now,
    );
    Ok(TaskStartSignalRecord {
        task_id: task_id.to_string(),
        runtime: agent.runtime.clone(),
        agent_id: agent_id.to_string(),
        signal_session_id: agent
            .agent_session_id
            .clone()
            .unwrap_or_else(|| state.session_id.clone()),
        signal,
    })
}

pub(crate) fn task_start_message(task: &WorkItem) -> String {
    let mut message = format!("Start work on task {}: {}", task.task_id, task.title);
    if let Some(context) = task.context.as_deref() {
        message.push_str("\n\nContext:\n");
        message.push_str(context);
    }
    if let Some(suggested_fix) = task.suggested_fix.as_deref() {
        message.push_str("\n\nSuggested fix:\n");
        message.push_str(suggested_fix);
    }
    message
}

pub(crate) fn task_start_action_hint(task_id: &str) -> String {
    format!("task:{task_id}")
}

pub(crate) fn start_next_locked_task_for_worker(
    state: &mut SessionState,
    worker_id: &str,
    actor_id: &str,
    now: &str,
    effects: &mut Vec<TaskDropEffect>,
) -> Result<bool, CliError> {
    let mut queued_tasks: Vec<_> = state
        .tasks
        .values()
        .filter(|task| {
            task.status == TaskStatus::Open
                && task.assigned_to.as_deref() == Some(worker_id)
                && task.queued_at.is_some()
        })
        .map(|task| {
            (
                task.queue_policy,
                task.queued_at.clone().unwrap_or_default(),
                task.task_id.clone(),
            )
        })
        .collect();
    queued_tasks.sort_unstable();
    let Some((TaskQueuePolicy::Locked, _, task_id)) = queued_tasks.first().cloned() else {
        return Ok(false);
    };
    start_task_for_agent(state, &task_id, worker_id, actor_id, now, effects)?;
    Ok(true)
}

pub(crate) fn free_worker_ids(state: &SessionState) -> Vec<String> {
    state
        .agents
        .values()
        .filter(|agent| agent.status.accepts_assignment() && agent.role == SessionRole::Worker)
        .filter(|agent| is_worker_free(state, &agent.agent_id))
        .map(|agent| agent.agent_id.clone())
        .collect()
}

pub(crate) fn is_worker_free(state: &SessionState, agent_id: &str) -> bool {
    let Some(agent) = state.agents.get(agent_id) else {
        return false;
    };
    agent.status.accepts_assignment()
        && agent.role == SessionRole::Worker
        && agent.current_task_id.is_none()
        && !state.tasks.values().any(|task| {
            task.assigned_to.as_deref() == Some(agent_id)
                && matches!(task.status, TaskStatus::InProgress | TaskStatus::InReview)
        })
}
