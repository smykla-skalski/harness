use super::{
    AgentStatus, AwaitingReview, CliError, CliErrorKind, SessionAction, SessionState, TaskStatus,
    clear_agent_current_task, refresh_session, require_active, require_permission,
    task_not_found, task_status_label, touch_agent,
};

const DEFAULT_REQUIRED_CONSENSUS: u8 = 2;

/// Transition a task from `InProgress` to `AwaitingReview`.
///
/// The submitting worker must be the actor and own the current assignment.
/// The task is unassigned, returned to the awaiting-review queue, and the
/// worker's agent status flips to [`AgentStatus::AwaitingReview`] so the
/// leader cannot hand the worker new work until the review round closes.
///
/// # Errors
/// - session is not active
/// - actor lacks [`SessionAction::UpdateTaskStatus`]
/// - task does not exist, is not `InProgress`, or is not assigned to the actor
pub(crate) fn apply_submit_for_review(
    state: &mut SessionState,
    task_id: &str,
    actor_id: &str,
    summary: Option<&str>,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::UpdateTaskStatus)?;

    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;

    if task.status != TaskStatus::InProgress {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' is {}; submit_for_review requires 'in progress'",
            task_status_label(task.status)
        ))
        .into());
    }

    let assignee = task.assigned_to.clone().ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' has no assignee; submit_for_review requires an assigned worker"
        )))
    })?;

    if assignee != actor_id {
        return Err(CliErrorKind::session_permission_denied(format!(
            "task '{task_id}' is assigned to '{assignee}'; only the assignee may submit it for review"
        ))
        .into());
    }

    clear_agent_current_task(state, &assignee, task_id, now);

    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.status = TaskStatus::AwaitingReview;
    task.assigned_to = None;
    task.queued_at = None;
    task.completed_at = None;
    task.blocked_reason = None;
    task.updated_at = now.to_string();
    task.awaiting_review = Some(AwaitingReview {
        queued_at: now.to_string(),
        submitter_agent_id: assignee.clone(),
        summary: summary.map(ToString::to_string),
        required_consensus: DEFAULT_REQUIRED_CONSENSUS,
    });

    if let Some(agent) = state.agents.get_mut(&assignee) {
        agent.status = AgentStatus::AwaitingReview;
        agent.current_task_id = None;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(())
}
