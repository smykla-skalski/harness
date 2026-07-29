use crate::types::ARBITRATION_BLOCKED_REASON;

use super::{
    CliError, CliErrorKind, DeliveryConfig, Duration, SessionAction, SessionState, Signal,
    SignalPayload, SignalPriority, TaskCheckpoint, TaskCheckpointSummary, TaskNote,
    TaskQueuePolicy, TaskSpec, TaskStatus, Utc, Value, WorkItem, agent_status_label,
    clear_agent_current_task, generate_checkpoint_id, generate_signal_id, next_task_id,
    refresh_session, require_active, require_managed_run_mutation, require_permission,
    require_task_creation_state, task_not_found, task_status_label, touch_agent,
};

/// Create a work item. Returns the new `WorkItem`.
///
/// # Errors
/// Returns [`CliError`] under the same conditions as
/// [`apply_create_task_with_id`].
pub fn apply_create_task(
    state: &mut SessionState,
    spec: &TaskSpec<'_>,
    actor_id: &str,
    now: &str,
) -> Result<WorkItem, CliError> {
    let task_id = next_task_id(&state.tasks);
    apply_create_task_with_id(state, &task_id, spec, actor_id, now)
}

/// Create a work item with a caller-reserved identity.
///
/// Durable dispatch uses this after reserving the identity in `SQLite` so a
/// retry can observe the same task instead of creating an orphan duplicate.
///
/// # Errors
/// Returns [`CliError`] when the session cannot accept task mutations, the
/// actor lacks [`SessionAction::CreateTask`], or `task_id` already exists.
pub fn apply_create_task_with_id(
    state: &mut SessionState,
    task_id: &str,
    spec: &TaskSpec<'_>,
    actor_id: &str,
    now: &str,
) -> Result<WorkItem, CliError> {
    require_task_creation_state(state)?;
    require_permission(state, actor_id, SessionAction::CreateTask)?;
    if state.tasks.contains_key(task_id) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' already exists in session '{}'",
            state.session_id
        ))
        .into());
    }
    let item = WorkItem {
        task_id: task_id.to_string(),
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
        awaiting_review: None,
        review_claim: None,
        consensus: None,
        review_history: Vec::new(),
        review_round: 0,
        arbitration: None,
        suggested_persona: None,
        deleted_at: None,
    };
    state.tasks.insert(task_id.to_string(), item.clone());
    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(item)
}

fn reject_review_only_status(task_id: &str, status: TaskStatus) -> Result<(), CliError> {
    if matches!(status, TaskStatus::AwaitingReview | TaskStatus::InReview) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' cannot transition to '{}' via generic update; use submit_for_review or claim_review",
            task_status_label(status)
        ))
        .into());
    }
    Ok(())
}

/// # Errors
/// Returns [`CliError`] when the task is `AwaitingReview`, `InReview`, or
/// blocked by arbitration.
pub fn reject_generic_mutation_on_review_state(
    task_id: &str,
    task: &WorkItem,
    operation: &str,
) -> Result<(), CliError> {
    if matches!(
        task.status,
        TaskStatus::AwaitingReview | TaskStatus::InReview
    ) || is_arbitration_blocked(task)
    {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' is {} and cannot be {operation}; use respond_review or arbitrate",
            task_status_label(task.status)
        ))
        .into());
    }
    Ok(())
}

/// # Errors
/// Returns [`CliError`] when `task` has already been deleted.
pub fn ensure_task_not_deleted(task_id: &str, task: &WorkItem) -> Result<(), CliError> {
    if task.is_deleted() {
        return Err(
            CliErrorKind::session_agent_conflict(format!("task '{task_id}' was deleted")).into(),
        );
    }
    Ok(())
}

#[must_use]
pub fn is_arbitration_blocked(task: &WorkItem) -> bool {
    task.status == TaskStatus::Blocked
        && task.blocked_reason.as_deref() == Some(ARBITRATION_BLOCKED_REASON)
}

/// Update a task's status. Returns the previous status.
///
/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::UpdateTaskStatus`], or the update itself fails; see
/// [`apply_update_task_fields`].
pub fn apply_update_task(
    state: &mut SessionState,
    task_id: &str,
    status: TaskStatus,
    note: Option<&str>,
    actor_id: &str,
    now: &str,
) -> Result<TaskStatus, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;

    apply_update_task_fields(state, task_id, status, note, actor_id, now)
}

/// Apply a daemon-managed run status without requiring a session leader.
///
/// # Errors
/// Returns [`CliError`] when the session cannot accept a managed-run
/// mutation, the actor lacks [`SessionAction::UpdateTaskStatus`], or the
/// update itself fails; see [`apply_update_task_fields`].
pub fn apply_update_task_for_managed_run(
    state: &mut SessionState,
    task_id: &str,
    status: TaskStatus,
    note: Option<&str>,
    actor_id: &str,
    now: &str,
) -> Result<TaskStatus, CliError> {
    require_managed_run_mutation(state)?;
    require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;
    apply_update_task_fields(state, task_id, status, note, actor_id, now)
}

fn apply_update_task_fields(
    state: &mut SessionState,
    task_id: &str,
    status: TaskStatus,
    note: Option<&str>,
    actor_id: &str,
    now: &str,
) -> Result<TaskStatus, CliError> {
    reject_review_only_status(task_id, status)?;

    let current_task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    ensure_task_not_deleted(task_id, current_task)?;
    reject_generic_mutation_on_review_state(task_id, current_task, "updated generically")?;
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
        TaskStatus::Open
        | TaskStatus::InProgress
        | TaskStatus::AwaitingReview
        | TaskStatus::InReview => {
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
///
/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::UpdateTaskStatus`], the task does not exist or is
/// already deleted, or the task is in a review state that rejects generic
/// mutation.
pub fn apply_record_checkpoint(
    state: &mut SessionState,
    task_id: &str,
    actor_id: &str,
    summary: &str,
    progress: u8,
    now: &str,
) -> Result<TaskCheckpoint, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;

    let current_task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    ensure_task_not_deleted(task_id, current_task)?;
    reject_generic_mutation_on_review_state(task_id, current_task, "checkpointed")?;
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
///
/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::SendSignal`], the target agent does not exist, or the
/// target agent is not alive.
pub fn apply_send_signal_state(
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
            agent_status_label(&target_agent.status)
        ))
        .into());
    }

    let runtime_name = target_agent.runtime.to_string();
    let target_agent_session_id = target_agent.agent_session_id.clone();
    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok((runtime_name, target_agent_session_id))
}

/// Build a signal payload without writing it to disk. Used by the daemon
/// handler which writes to `SQLite` first, then writes the signal file, so
/// this stays `pub` across the crate boundary rather than `pub(crate)`.
pub fn build_signal(
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

#[cfg(test)]
#[path = "task_state_persona_tests.rs"]
mod persona_routing_tests;
