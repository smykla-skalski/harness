use super::super::{
    AgentStatus, AwaitingReview, CliError, CliErrorKind, SessionAction, SessionState, TaskStatus,
    clear_agent_current_task, refresh_session, require_active, require_permission,
    task_not_found, task_status_label, touch_agent,
};
use crate::session::types::{
    Review, ReviewClaim, ReviewConsensus, ReviewPoint, ReviewVerdict, ReviewerEntry,
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

/// Record a reviewer's submitted review on the task and close quorum if
/// the distinct-runtime submission count meets `required_consensus`.
///
/// The reviewer must already hold a claim; calling this before
/// `apply_claim_review` is rejected. Submitting twice from the same
/// reviewer updates `submitted_at` to the latest timestamp and rebuilds
/// consensus from the supplied `all_reviews` slice; file-level
/// idempotency on `review_id` lives in `storage::journal::append_review`.
///
/// # Errors
/// - session is not active
/// - actor lacks [`SessionAction::SubmitReview`]
/// - task missing, not in `InReview`, or reviewer has no claim on it
pub(crate) fn apply_submit_review(
    state: &mut SessionState,
    task_id: &str,
    review: &Review,
    all_reviews: &[Review],
    now: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, &review.reviewer_agent_id, SessionAction::SubmitReview)?;

    let task = state
        .tasks
        .get(task_id)
        .ok_or_else(|| task_not_found(task_id))?;

    if task.status != TaskStatus::InReview {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' is {}; submit_review requires 'in review'",
            task_status_label(task.status)
        ))
        .into());
    }

    let claim = task.review_claim.as_ref().ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' has no reviewer claim; claim_review before submit_review"
        )))
    })?;
    if !claim
        .reviewers
        .iter()
        .any(|entry| entry.reviewer_agent_id == review.reviewer_agent_id)
    {
        return Err(CliErrorKind::session_permission_denied(format!(
            "reviewer '{}' has not claimed task '{task_id}'",
            review.reviewer_agent_id
        ))
        .into());
    }

    let required = task
        .awaiting_review
        .as_ref()
        .map_or(2u8, |meta| meta.required_consensus);

    let task = state
        .tasks
        .get_mut(task_id)
        .ok_or_else(|| task_not_found(task_id))?;
    task.updated_at = now.to_string();
    if let Some(claim) = task.review_claim.as_mut()
        && let Some(entry) = claim
            .reviewers
            .iter_mut()
            .find(|entry| entry.reviewer_agent_id == review.reviewer_agent_id)
    {
        entry.submitted_at = Some(now.to_string());
    }

    try_close_quorum(state, task_id, all_reviews, required, now);

    touch_agent(state, &review.reviewer_agent_id, now);
    refresh_session(state, now);
    Ok(())
}

/// Aggregate submitted reviews and stamp `ReviewConsensus` when the
/// distinct-runtime count meets `required_consensus`. On an all-approve
/// consensus the task transitions to `Done`; otherwise the task stays in
/// `InReview` carrying the aggregated verdict for the worker response.
fn try_close_quorum(
    state: &mut SessionState,
    task_id: &str,
    all_reviews: &[Review],
    required: u8,
    now: &str,
) {
    let Some(task) = state.tasks.get_mut(task_id) else {
        return;
    };
    let Some(claim) = task.review_claim.as_ref() else {
        return;
    };

    let submitted: Vec<&ReviewerEntry> = claim
        .reviewers
        .iter()
        .filter(|entry| entry.submitted_at.is_some())
        .collect();
    let mut distinct_runtimes: Vec<&str> = submitted
        .iter()
        .map(|entry| entry.reviewer_runtime.as_str())
        .collect();
    distinct_runtimes.sort_unstable();
    distinct_runtimes.dedup();
    if u8::try_from(distinct_runtimes.len()).unwrap_or(u8::MAX) < required {
        return;
    }

    let relevant: Vec<&Review> = all_reviews
        .iter()
        .filter(|review| {
            submitted
                .iter()
                .any(|entry| entry.reviewer_agent_id == review.reviewer_agent_id)
        })
        .collect();
    let verdict = aggregate_verdict(&relevant);
    let summary = relevant
        .iter()
        .map(|review| review.summary.clone())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("; ");
    let points = collect_consensus_points(&relevant);
    let reviewer_agent_ids = submitted
        .iter()
        .map(|entry| entry.reviewer_agent_id.clone())
        .collect();

    task.consensus = Some(ReviewConsensus {
        verdict,
        summary,
        points,
        closed_at: now.to_string(),
        reviewer_agent_ids,
    });
    if verdict == ReviewVerdict::Approve {
        task.status = TaskStatus::Done;
        task.completed_at = Some(now.to_string());
    }
}

fn aggregate_verdict(reviews: &[&Review]) -> ReviewVerdict {
    if reviews.iter().all(|r| r.verdict == ReviewVerdict::Approve) {
        ReviewVerdict::Approve
    } else if reviews.iter().any(|r| r.verdict == ReviewVerdict::Reject) {
        ReviewVerdict::Reject
    } else {
        ReviewVerdict::RequestChanges
    }
}

fn collect_consensus_points(reviews: &[&Review]) -> Vec<ReviewPoint> {
    let mut aggregated: Vec<ReviewPoint> = Vec::new();
    for review in reviews {
        for point in &review.points {
            if !aggregated
                .iter()
                .any(|existing| existing.point_id == point.point_id)
            {
                aggregated.push(point.clone());
            }
        }
    }
    aggregated
}
