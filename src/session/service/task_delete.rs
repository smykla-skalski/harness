use super::{
    AgentStatus, CliError, SessionAction, SessionState, TaskQueuePolicy, TaskStatus,
    clear_agent_current_task, ensure_task_not_deleted, refresh_session, require_permission,
    require_task_creation_state, task_not_found, touch_agent,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DeletedTaskInfo {
    pub(crate) title: String,
    pub(crate) previous_status: TaskStatus,
}

pub(crate) fn apply_delete_task(
    state: &mut SessionState,
    task_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<DeletedTaskInfo, CliError> {
    require_task_creation_state(state)?;
    require_permission(state, actor_id, SessionAction::DeleteTask)?;

    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    ensure_task_not_deleted(task_id, task)?;

    let deleted = DeletedTaskInfo {
        title: task.title.clone(),
        previous_status: task.status,
    };
    let assigned_to = task.assigned_to.clone();
    let submitter_agent_id = task
        .awaiting_review
        .as_ref()
        .map(|awaiting| awaiting.submitter_agent_id.clone());

    if let Some(assigned_to) = assigned_to.as_deref() {
        clear_agent_current_task(state, assigned_to, task_id, now);
        if let Some(agent) = state.agents.get_mut(assigned_to) {
            agent.updated_at = now.to_string();
            agent.last_activity_at = Some(now.to_string());
        }
    }

    if let Some(submitter_agent_id) = submitter_agent_id
        && let Some(agent) = state.agents.get_mut(&submitter_agent_id)
        && agent.status == AgentStatus::AwaitingReview
    {
        agent.status = AgentStatus::Idle;
        agent.current_task_id = None;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }

    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    // Preserve task identity/history via tombstone while clearing live
    // coordination fields so the deleted task cannot re-enter queue/review flow.
    task.deleted_at = Some(now.to_string());
    task.status = TaskStatus::Done;
    task.assigned_to = None;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.awaiting_review = None;
    task.review_claim = None;
    task.consensus = None;
    task.blocked_reason = None;
    task.completed_at = None;
    task.updated_at = now.to_string();

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(deleted)
}
