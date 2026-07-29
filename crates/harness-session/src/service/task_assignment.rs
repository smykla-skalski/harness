use super::{
    AgentRegistration, CliError, SessionAction, SessionState, TaskDropEffect, TaskQueuePolicy,
    TaskStatus, apply_drop_task_on_agent, ensure_task_not_deleted, free_worker_ids,
    rank_workers_for_task, refresh_session, reject_generic_mutation_on_review_state,
    require_active, require_permission, start_next_locked_task_for_worker, start_task_for_agent,
    task_not_found, touch_agent, wire,
};

/// Assign a task to an agent.
///
/// Assignment is the canonical Locked drop: it delegates to
/// `apply_drop_task_on_agent` with `TaskQueuePolicy::Locked`. A task-start
/// signal is produced when the worker is free; otherwise the task is queued
/// against the worker. The agent's `current_task_id` is set eagerly by
/// `start_task_for_agent` so a subsequent `drop_task` on a different task is
/// queued correctly. Sharing the drop code path keeps signal delivery
/// consistent across the assign and drag-drop UI gestures.
///
/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::AssignTask`], or the drop itself fails; see
/// [`apply_drop_task_on_agent`].
pub fn apply_assign_task(
    state: &mut SessionState,
    task_id: &str,
    agent_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::AssignTask)?;
    apply_drop_task_on_agent(
        state,
        task_id,
        agent_id,
        TaskQueuePolicy::Locked,
        actor_id,
        now,
    )
}

/// Drop a task onto an extensible session target. The first target action is
/// worker assignment: start immediately when the worker is free, otherwise
/// queue against the selected worker.
///
/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::AssignTask`], or the drop itself fails; see
/// [`apply_drop_task_on_agent`].
pub fn apply_drop_task(
    state: &mut SessionState,
    task_id: &str,
    target: &wire::TaskDropTarget,
    queue_policy: TaskQueuePolicy,
    actor_id: &str,
    now: &str,
) -> Result<Vec<TaskDropEffect>, CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::AssignTask)?;

    match target {
        wire::TaskDropTarget::Agent { agent_id } => {
            apply_drop_task_on_agent(state, task_id, agent_id, queue_policy, actor_id, now)
        }
    }
}

/// # Errors
/// Returns [`CliError`] when the session is not active, the actor lacks
/// [`SessionAction::AssignTask`], the task does not exist or is already
/// deleted, or the task is in a review state that rejects generic mutation.
pub fn apply_update_task_queue_policy(
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
    ensure_task_not_deleted(task_id, task)?;
    reject_generic_mutation_on_review_state(task_id, task, "queue policy changed")?;
    task.queue_policy = queue_policy;
    task.updated_at = now.to_string();
    touch_agent(state, actor_id, now);
    let effects = apply_advance_queued_tasks(state, actor_id, now)?;
    refresh_session(state, now);
    Ok(effects)
}

/// # Errors
/// Returns [`CliError`] under the same conditions as
/// [`start_next_locked_task_for_worker`] and [`start_task_for_agent`].
pub fn apply_advance_queued_tasks(
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
            !task.is_deleted()
                && task.status == TaskStatus::Open
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
        if free_workers.is_empty() {
            break;
        }
        let worker_id = select_worker_for_task(state, &task_id, &free_workers)
            .or_else(|| free_workers.first().cloned());
        let Some(worker_id) = worker_id else {
            break;
        };
        start_task_for_agent(state, &task_id, &worker_id, actor_id, now, &mut effects)?;
        free_workers.retain(|candidate| candidate != &worker_id);
    }

    Ok(effects)
}

fn select_worker_for_task(
    state: &SessionState,
    task_id: &str,
    free_workers: &[String],
) -> Option<String> {
    let task = state.tasks.get(task_id)?;
    let agents: Vec<&AgentRegistration> = free_workers
        .iter()
        .filter_map(|id| state.agents.get(id))
        .collect();
    let ranked = rank_workers_for_task(task, &agents);
    ranked.into_iter().next()
}
