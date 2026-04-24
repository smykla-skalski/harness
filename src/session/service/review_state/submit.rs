use std::collections::BTreeMap;

use super::super::{
    AgentStatus, AwaitingReview, CliError, CliErrorKind, SessionAction, SessionState, TaskStatus,
    clear_agent_current_task, refresh_session, require_active, require_permission, task_not_found,
    task_status_label, touch_agent,
};
use crate::session::types::{
    Review, ReviewClaim, ReviewConsensus, ReviewPoint, ReviewVerdict, ReviewerEntry, WorkItem,
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

/// Read-only guardrail for [`apply_submit_review`].
///
/// Callers must invoke this BEFORE writing the review record to disk,
/// so an unauthorized or out-of-state submission leaves no durable
/// journal entry in `tasks/<task_id>/reviews.jsonl`.
///
/// # Errors
/// - session is not active
/// - actor lacks [`SessionAction::SubmitReview`]
/// - task missing, not in `InReview`, or reviewer has no claim on it
pub(crate) fn validate_submit_review(
    state: &SessionState,
    task_id: &str,
    reviewer_agent_id: &str,
) -> Result<(), CliError> {
    require_active(state)?;
    require_permission(state, reviewer_agent_id, SessionAction::SubmitReview)?;

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
        .any(|entry| entry.reviewer_agent_id == reviewer_agent_id)
    {
        return Err(CliErrorKind::session_permission_denied(format!(
            "reviewer '{reviewer_agent_id}' has not claimed task '{task_id}'"
        ))
        .into());
    }
    Ok(())
}

/// Record a reviewer's submitted review on the task and close quorum if
/// the distinct-runtime submission count meets `required_consensus`.
///
/// The reviewer must already hold a claim; calling this before
/// [`apply_claim_review`] is rejected. Submitting twice from the same
/// reviewer updates `submitted_at` and rebuilds consensus from the
/// supplied `all_reviews` slice; file-level idempotency on `review_id`
/// lives in [`crate::session::storage::files::append_review`].
///
/// # Errors
/// Same error set as [`validate_submit_review`].
pub(crate) fn apply_submit_review(
    state: &mut SessionState,
    task_id: &str,
    review: &Review,
    all_reviews: &[Review],
    now: &str,
) -> Result<(), CliError> {
    validate_submit_review(state, task_id, &review.reviewer_agent_id)?;

    let required = state
        .tasks
        .get(task_id)
        .and_then(|task| task.awaiting_review.as_ref())
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
    let (submitted_ids, submitter_id, current_round) = {
        let Some(task) = state.tasks.get(task_id) else {
            return;
        };
        let Some(entries) = quorum_submitted_entries(task, required) else {
            return;
        };
        let submitted_ids: Vec<String> = entries
            .iter()
            .map(|entry| entry.reviewer_agent_id.clone())
            .collect();
        let current_round = task.review_round.saturating_add(1);
        let submitter = task
            .awaiting_review
            .as_ref()
            .map(|meta| meta.submitter_agent_id.clone());
        (submitted_ids, submitter, current_round)
    };
    let relevant = filter_reviews_for_round(all_reviews, &submitted_ids, current_round);
    if u8::try_from(distinct_runtimes(&relevant)).unwrap_or(u8::MAX) < required {
        return;
    }
    let verdict = aggregate_verdict(&relevant);
    if let Some(task) = state.tasks.get_mut(task_id) {
        stamp_consensus(task, &submitted_ids, &relevant, verdict, now);
    }
    if verdict == ReviewVerdict::Approve {
        close_task_as_done(state, task_id, submitter_id, now);
    }
}

fn distinct_runtimes(reviews: &[&Review]) -> usize {
    let mut runtimes: Vec<&str> = reviews
        .iter()
        .map(|review| review.reviewer_runtime.as_str())
        .collect();
    runtimes.sort_unstable();
    runtimes.dedup();
    runtimes.len()
}

fn quorum_submitted_entries(task: &WorkItem, required: u8) -> Option<Vec<&ReviewerEntry>> {
    let claim = task.review_claim.as_ref()?;
    let submitted: Vec<&ReviewerEntry> = claim
        .reviewers
        .iter()
        .filter(|entry| entry.submitted_at.is_some())
        .collect();
    let mut distinct: Vec<&str> = submitted
        .iter()
        .map(|entry| entry.reviewer_runtime.as_str())
        .collect();
    distinct.sort_unstable();
    distinct.dedup();
    if u8::try_from(distinct.len()).unwrap_or(u8::MAX) < required {
        return None;
    }
    Some(submitted)
}

fn filter_reviews_for_round<'a>(
    all_reviews: &'a [Review],
    submitted_ids: &[String],
    current_round: u8,
) -> Vec<&'a Review> {
    let mut latest: BTreeMap<&str, &Review> = BTreeMap::new();
    for review in all_reviews {
        if review.round != current_round {
            continue;
        }
        if !submitted_ids
            .iter()
            .any(|id| id == &review.reviewer_agent_id)
        {
            continue;
        }
        let keep = latest
            .get(review.reviewer_agent_id.as_str())
            .is_none_or(|existing| review.recorded_at.as_str() >= existing.recorded_at.as_str());
        if keep {
            latest.insert(review.reviewer_agent_id.as_str(), review);
        }
    }
    latest.into_values().collect()
}

fn stamp_consensus(
    task: &mut WorkItem,
    submitted_ids: &[String],
    relevant: &[&Review],
    verdict: ReviewVerdict,
    now: &str,
) {
    let summary = relevant
        .iter()
        .map(|review| review.summary.clone())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("; ");
    let points = collect_consensus_points(relevant);
    task.consensus = Some(ReviewConsensus {
        verdict,
        summary,
        points,
        closed_at: now.to_string(),
        reviewer_agent_ids: submitted_ids.to_vec(),
    });
}

fn close_task_as_done(
    state: &mut SessionState,
    task_id: &str,
    submitter_id: Option<String>,
    now: &str,
) {
    if let Some(task) = state.tasks.get_mut(task_id) {
        task.status = TaskStatus::Done;
        task.completed_at = Some(now.to_string());
        task.assigned_to = None;
        task.awaiting_review = None;
        task.review_claim = None;
    }
    if let Some(submitter_id) = submitter_id
        && let Some(agent) = state.agents.get_mut(&submitter_id)
    {
        agent.status = AgentStatus::Idle;
        agent.current_task_id = None;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
}

fn aggregate_verdict(reviews: &[&Review]) -> ReviewVerdict {
    if reviews.is_empty() {
        return ReviewVerdict::RequestChanges;
    }
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

#[cfg(test)]
mod tests {
    use super::{aggregate_verdict, distinct_runtimes};
    use crate::session::types::{Review, ReviewVerdict};

    fn review(runtime: &str, verdict: ReviewVerdict) -> Review {
        Review {
            review_id: format!("r-{runtime}"),
            round: 1,
            reviewer_agent_id: format!("{runtime}-1"),
            reviewer_runtime: runtime.to_string(),
            verdict,
            summary: String::new(),
            points: Vec::new(),
            recorded_at: "t".to_string(),
        }
    }

    #[test]
    fn aggregate_verdict_empty_is_request_changes_not_approve() {
        let empty: Vec<&Review> = Vec::new();
        assert_eq!(aggregate_verdict(&empty), ReviewVerdict::RequestChanges);
    }

    #[test]
    fn distinct_runtimes_counts_unique_runtimes() {
        let a = review("gemini", ReviewVerdict::Approve);
        let b = review("gemini", ReviewVerdict::Approve);
        let c = review("claude", ReviewVerdict::Approve);
        assert_eq!(distinct_runtimes(&[&a, &b, &c]), 2);
    }
}
