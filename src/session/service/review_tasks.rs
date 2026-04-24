//! Public service facades for the review workflow.
//!
//! Split out of `tasks.rs` to keep each file under the repo-wide
//! file-length gate while the review workflow accrues additional steps
//! (arbitration, improver apply, etc.).

use super::{
    CliError, Path, TaskStatus, apply_arbitrate, apply_claim_review, apply_respond_review,
    apply_submit_for_review, apply_submit_review, generate_review_id, load_state_or_err,
    log_signal_sent, log_task_status_changed, maybe_emit_spawn_reviewer, storage, utc_now,
    validate_submit_review,
};
use crate::agents::runtime::runtime_for_name;
use crate::session::types::{Review, ReviewPoint, ReviewVerdict};
/// Submit a task for review.
///
/// Transitions the task from `InProgress` to `AwaitingReview`, unassigns it,
/// and flips the submitting worker's agent status to
/// `AgentStatus::AwaitingReview`.
///
/// # Errors
/// Returns `CliError` if the session is not active, the task is not
/// `InProgress`, the task is not assigned to the actor, or storage fails.
pub fn submit_for_review(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    summary: Option<&str>,
    project_dir: &Path,
) -> Result<(), CliError> {
    submit_for_review_with_persona(session_id, task_id, actor_id, summary, None, project_dir)
}

/// Submit a task for review with an explicit `suggested_persona` hint.
///
/// The hint is persisted on `WorkItem::suggested_persona` so the queue
/// reassignment path can bias worker selection when the task re-enters
/// the queue.
///
/// # Errors
/// Same error surface as `submit_for_review`.
pub fn submit_for_review_with_persona(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    summary: Option<&str>,
    suggested_persona: Option<&str>,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state(&layout, |state| {
        apply_submit_for_review(state, task_id, actor_id, summary, &now)?;
        if let Some(persona) = suggested_persona
            && let Some(task) = state.tasks.get_mut(task_id)
        {
            task.suggested_persona = Some(persona.to_string());
        }
        Ok(())
    })?;

    storage::append_log_entry(
        &layout,
        log_task_status_changed(task_id, TaskStatus::InProgress, TaskStatus::AwaitingReview),
        Some(actor_id),
        None,
    )?;

    // Auto-spawn reviewer when no reviewer is present: materialize the
    // signal on disk against the leader's runtime so hooks can pick it up.
    let state_after = load_state_or_err(session_id, project_dir)?;
    if let Some(record) = maybe_emit_spawn_reviewer(&state_after, task_id, &now)
        && let Some(runtime) = runtime_for_name(&record.runtime)
    {
        let target_session_id = state_after
            .agents
            .get(&record.agent_id)
            .and_then(|agent| agent.agent_session_id.clone())
            .unwrap_or_else(|| record.session_id.clone());
        runtime.write_signal(project_dir, &target_session_id, &record.signal)?;
        storage::append_log_entry(
            &layout,
            log_signal_sent(
                &record.signal.signal_id,
                &record.agent_id,
                &record.signal.command,
            ),
            None,
            None,
        )?;
    }
    Ok(())
}

/// Claim a review slot on a task awaiting review.
///
/// Records the reviewer entry, transitions the task from `AwaitingReview`
/// to `InReview` on the first claim, and enforces single-reviewer-per-
/// runtime.
///
/// # Errors
/// Returns `CliError` if the session is not active, the task is not in a
/// reviewable state, the actor lacks `ClaimReview` permission, or a
/// same-runtime reviewer already holds a claim on the task.
pub fn claim_review(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    let prev_status = load_state_or_err(session_id, project_dir)?
        .tasks
        .get(task_id)
        .map(|task| task.status);
    let new_state = storage::update_state(&layout, |state| {
        apply_claim_review(state, task_id, actor_id, &now)
    })?;
    let new_status = new_state.tasks.get(task_id).map(|task| task.status);

    if let (Some(prev), Some(new)) = (prev_status, new_status)
        && prev != new
    {
        storage::append_log_entry(
            &layout,
            log_task_status_changed(task_id, prev, new),
            Some(actor_id),
            None,
        )?;
    }
    Ok(())
}

/// Submit a reviewer's verdict on a task that is `InReview`.
///
/// Appends the record to `tasks/<task_id>/reviews.jsonl` (idempotent on
/// `review_id`), stamps the reviewer's `submitted_at`, and closes quorum
/// if the distinct-runtime submission count meets `required_consensus`.
///
/// # Errors
/// Returns `CliError` if the session is not active, the reviewer lacks
/// `SubmitReview` permission or has no claim on the task, the task is
/// not `InReview`, or storage fails.
pub fn submit_review(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    verdict: ReviewVerdict,
    summary: &str,
    points: Vec<ReviewPoint>,
    project_dir: &Path,
) -> Result<Review, CliError> {
    let now = utc_now();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    let state_before = load_state_or_err(session_id, project_dir)?;
    validate_submit_review(&state_before, task_id, actor_id)?;
    let round = state_before
        .tasks
        .get(task_id)
        .map_or(1, |task| task.review_round.saturating_add(1));
    let reviewer_runtime = state_before
        .agents
        .get(actor_id)
        .map(|agent| agent.runtime.clone())
        .unwrap_or_default();
    let review = Review {
        review_id: generate_review_id(task_id),
        round,
        reviewer_agent_id: actor_id.to_string(),
        reviewer_runtime,
        verdict,
        summary: summary.to_string(),
        points,
        recorded_at: now.clone(),
    };

    storage::append_review(&layout, task_id, &review)?;
    let all_reviews = storage::load_reviews(&layout, task_id)?;

    let prev_status = state_before.tasks.get(task_id).map(|task| task.status);
    let new_state = storage::update_state(&layout, |state| {
        apply_submit_review(state, task_id, &review, &all_reviews, &now)
    })?;
    let new_status = new_state.tasks.get(task_id).map(|task| task.status);

    if let (Some(prev), Some(new)) = (prev_status, new_status)
        && prev != new
    {
        storage::append_log_entry(
            &layout,
            log_task_status_changed(task_id, prev, new),
            Some(actor_id),
            None,
        )?;
    }
    Ok(review)
}

/// Worker response to a request-changes consensus.
///
/// Increments `review_round`, folds agreed/disputed points into the
/// stored consensus, then either returns the task to `InProgress` with
/// the worker reassigned (all points agreed) or clears reviewer
/// `submitted_at` so the next round can re-form (any point disputed).
///
/// # Errors
/// Returns `CliError` if the session is not active, the actor is not
/// the original submitter, the task is not `InReview`, or no consensus
/// has been recorded.
pub fn respond_review(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    agreed: &[String],
    disputed: &[String],
    note: Option<&str>,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    let prev_status = load_state_or_err(session_id, project_dir)?
        .tasks
        .get(task_id)
        .map(|task| task.status);
    let new_state = storage::update_state(&layout, |state| {
        apply_respond_review(state, task_id, actor_id, agreed, disputed, note, &now)
    })?;
    let new_status = new_state.tasks.get(task_id).map(|task| task.status);

    if let (Some(prev), Some(new)) = (prev_status, new_status)
        && prev != new
    {
        storage::append_log_entry(
            &layout,
            log_task_status_changed(task_id, prev, new),
            Some(actor_id),
            None,
        )?;
    }
    Ok(())
}

/// Leader arbitration for a task stuck in the review/respond cycle.
///
/// Requires `review_round >= 3` and the actor must be the session leader.
/// Approve closes the task to `Done`; other verdicts record the
/// arbitration outcome without forcing a status change.
///
/// # Errors
/// Returns `CliError` if the session is not active, the actor is not the
/// leader, the actor lacks `Arbitrate`, the task is below the round
/// gate, or storage fails.
pub fn arbitrate(
    session_id: &str,
    task_id: &str,
    actor_id: &str,
    verdict: ReviewVerdict,
    summary: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let now = utc_now();
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    let prev_status = load_state_or_err(session_id, project_dir)?
        .tasks
        .get(task_id)
        .map(|task| task.status);
    let new_state = storage::update_state(&layout, |state| {
        apply_arbitrate(state, task_id, actor_id, verdict, summary, &now)
    })?;
    let new_status = new_state.tasks.get(task_id).map(|task| task.status);

    if let (Some(prev), Some(new)) = (prev_status, new_status)
        && prev != new
    {
        storage::append_log_entry(
            &layout,
            log_task_status_changed(task_id, prev, new),
            Some(actor_id),
            None,
        )?;
    }
    Ok(())
}
