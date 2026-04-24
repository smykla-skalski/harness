use super::super::{
    AgentStatus, CliError, CliErrorKind, SessionAction, SessionState, TaskStatus,
    refresh_session, require_active, require_permission, task_not_found, task_status_label,
    touch_agent,
};
use crate::session::types::{ArbitrationOutcome, ReviewPointState, ReviewVerdict, WorkItem};

pub(crate) fn apply_respond_review(
    state: &mut SessionState,
    task_id: &str,
    actor_id: &str,
    agreed: &[String],
    disputed: &[String],
    note: Option<&str>,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::RespondReview)?;

    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;

    if task.status != TaskStatus::InReview {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' is {}; respond_review requires 'in review'",
            task_status_label(task.status)
        ))
        .into());
    }
    if task.consensus.is_none() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' has no consensus to respond to"
        ))
        .into());
    }
    let submitter = task
        .awaiting_review
        .as_ref()
        .map(|meta| meta.submitter_agent_id.clone())
        .ok_or_else(|| {
            CliError::from(CliErrorKind::session_agent_conflict(format!(
                "task '{task_id}' is missing awaiting_review submitter metadata"
            )))
        })?;
    if submitter != actor_id {
        return Err(CliErrorKind::session_permission_denied(format!(
            "task '{task_id}' was submitted by '{submitter}'; only the submitter can respond"
        ))
        .into());
    }

    let has_disputed = !disputed.is_empty();

    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.updated_at = now.to_string();
    task.review_round = task.review_round.saturating_add(1);
    merge_points(task, agreed, disputed, note);
    task.consensus = None;

    if has_disputed {
        if let Some(claim) = task.review_claim.as_mut() {
            for entry in &mut claim.reviewers {
                entry.submitted_at = None;
            }
        }
    } else {
        task.status = TaskStatus::InProgress;
        task.assigned_to = Some(submitter.clone());
        task.awaiting_review = None;
        task.review_claim = None;
        if let Some(agent) = state.agents.get_mut(&submitter) {
            agent.status = AgentStatus::Active;
            agent.current_task_id = Some(task_id.to_string());
            agent.updated_at = now.to_string();
            agent.last_activity_at = Some(now.to_string());
        }
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(())
}

/// Fold the worker's agreed/disputed lists into `consensus.points`.
///
/// Agreed points flip to [`ReviewPointState::Resolved`]; disputed points
/// flip to [`ReviewPointState::Disputed`]. The worker's note, if any, is
/// copied onto every touched point. When the consensus object is absent
/// this is a no-op, so the caller can safely invoke it even for a bare
/// "no feedback" response.
fn merge_points(task: &mut WorkItem, agreed: &[String], disputed: &[String], note: Option<&str>) {
    let Some(consensus) = task.consensus.as_mut() else {
        return;
    };
    for point in &mut consensus.points {
        if agreed.iter().any(|id| id == &point.point_id) {
            point.state = ReviewPointState::Resolved;
            if let Some(text) = note {
                point.worker_note = Some(text.to_string());
            }
        } else if disputed.iter().any(|id| id == &point.point_id) {
            point.state = ReviewPointState::Disputed;
            if let Some(text) = note {
                point.worker_note = Some(text.to_string());
            }
        }
    }
}

const ARBITRATION_ROUND_GATE: u8 = 3;

/// Leader arbitrates a task that exhausted the three-round review cycle.
///
/// The actor must be the session leader and must hold the [`SessionAction::Arbitrate`]
/// permission. The task must have reached `review_round >= 3` so the worker
/// and reviewers had a full three-round opportunity to converge. Approve
/// closes the task to `Done`; `Reject` / `RequestChanges` record the verdict
/// but leave status decisions for the leader's follow-up work item.
///
/// # Errors
/// - session is not active
/// - actor is not the session leader
/// - actor lacks `Arbitrate`
/// - task missing or below the three-round gate
pub(crate) fn apply_arbitrate(
    state: &mut SessionState,
    task_id: &str,
    actor_id: &str,
    verdict: ReviewVerdict,
    summary: &str,
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, actor_id, SessionAction::Arbitrate)?;
    if state.leader_id.as_deref() != Some(actor_id) {
        return Err(CliErrorKind::session_permission_denied(format!(
            "only the session leader can arbitrate; actor '{actor_id}' is not leader"
        ))
        .into());
    }

    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    if task.review_round < ARBITRATION_ROUND_GATE {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' is at review_round {} but arbitration requires {ARBITRATION_ROUND_GATE} rounds",
            task.review_round
        ))
        .into());
    }

    let submitter = state
        .tasks
        .get(task_id)
        .and_then(|task| task.awaiting_review.as_ref())
        .map(|meta| meta.submitter_agent_id.clone());
    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.updated_at = now.to_string();
    task.arbitration = Some(ArbitrationOutcome {
        arbiter_agent_id: actor_id.to_string(),
        verdict,
        summary: summary.to_string(),
        recorded_at: now.to_string(),
    });
    if verdict == ReviewVerdict::Approve {
        task.status = TaskStatus::Done;
        task.completed_at = Some(now.to_string());
        task.assigned_to = None;
        task.review_claim = None;
        task.awaiting_review = None;
        task.consensus = None;
        if let Some(submitter_id) = submitter
            && let Some(agent) = state.agents.get_mut(&submitter_id)
        {
            agent.status = AgentStatus::Idle;
            agent.current_task_id = None;
            agent.updated_at = now.to_string();
            agent.last_activity_at = Some(now.to_string());
        }
    }

    touch_agent(state, actor_id, now);
    refresh_session(state, now);
    Ok(())
}
