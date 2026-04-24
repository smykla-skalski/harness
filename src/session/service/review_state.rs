use super::{
    AgentStatus, AwaitingReview, CliError, CliErrorKind, SessionAction, SessionState, TaskStatus,
    clear_agent_current_task, refresh_session, require_active, require_permission,
    task_not_found, task_status_label, touch_agent,
};
use crate::session::types::{ReviewClaim, ReviewerEntry};

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

/// Record a reviewer claim on a task that is awaiting review.
///
/// The first claim transitions the task from `AwaitingReview` to `InReview`.
/// Subsequent claims append to `review_claim.reviewers` so long as no
/// existing reviewer shares the claimant's runtime (single-per-runtime
/// discipline).
///
/// # Errors
/// - session is not active
/// - actor lacks [`SessionAction::ClaimReview`]
/// - task is not in `AwaitingReview` or `InReview`
/// - a reviewer of the same runtime already holds a claim on the task
pub(crate) fn apply_claim_review(
    state: &mut SessionState,
    task_id: &str,
    actor_id: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::ClaimReview)?;

    let actor_runtime = state
        .agents
        .get(actor_id)
        .ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "agent '{actor_id}' not found"
            )))
        })?
        .runtime
        .clone();

    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;

    if !matches!(
        task.status,
        TaskStatus::AwaitingReview | TaskStatus::InReview
    ) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' is {}; claim_review requires 'awaiting review' or 'in review'",
            task_status_label(task.status)
        ))
        .into());
    }

    if let Some(claim) = task.review_claim.as_ref()
        && claim
            .reviewers
            .iter()
            .any(|entry| entry.reviewer_runtime == actor_runtime)
    {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "runtime_already_reviewing: task '{task_id}' already has a reviewer on runtime '{actor_runtime}'"
        ))
        .into());
    }

    let entry = ReviewerEntry {
        reviewer_agent_id: actor_id.to_string(),
        reviewer_runtime: actor_runtime,
        claimed_at: now.to_string(),
        submitted_at: None,
    };

    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.updated_at = now.to_string();
    if task.status == TaskStatus::AwaitingReview {
        task.status = TaskStatus::InReview;
    }
    match task.review_claim.as_mut() {
        Some(claim) => claim.reviewers.push(entry),
        None => {
            task.review_claim = Some(ReviewClaim {
                reviewers: vec![entry],
            });
        }
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(())
}
