//! Helpers split out of `review_mutations::submit_review_async` so the
//! `SQLite` immediate transaction only performs state mutation. File I/O
//! (append `reviews.jsonl`, reload) runs before the transaction opens,
//! and the per-review mirror insert runs after. Ordering:
//!
//! 1. `prepare_submit_review` appends the new row to `reviews.jsonl`
//!    (idempotent on `review_id`) and reloads the full set.
//! 2. The caller opens the immediate `SQLite` transaction and invokes
//!    `apply_submit_review_in_txn`, which only does in-memory validation
//!    plus the consensus state mutation.
//! 3. The caller inserts the single review into `task_reviews` after
//!    the transaction commits.
//!
//! If the daemon crashes between (1) and (2), `rebuild_task_reviews` on
//! next start replays the jsonl into `SQLite`. If the process crashes
//! between (2) and (3), `rebuild_task_reviews` similarly backfills.

use crate::errors::CliError;
use crate::session::service::{apply_submit_review, generate_review_id, validate_submit_review};
use crate::session::storage as session_storage;
use crate::session::types::{Review, ReviewPoint, ReviewVerdict, SessionState, TaskStatus};
use crate::workspace::layout::SessionLayout;

pub(super) struct PreparedSubmitReview {
    pub(super) review: Review,
    pub(super) all_reviews: Vec<Review>,
}

#[expect(
    clippy::too_many_arguments,
    reason = "captures full submit_review context for pre-txn append + load"
)]
pub(super) fn prepare_submit_review(
    state: &SessionState,
    task_id: &str,
    actor: &str,
    verdict: ReviewVerdict,
    summary: &str,
    points: &[ReviewPoint],
    layout: &SessionLayout,
    now: &str,
) -> Result<PreparedSubmitReview, CliError> {
    let round = state
        .tasks
        .get(task_id)
        .map_or(1, |task| task.review_round.saturating_add(1));
    let reviewer_runtime = state
        .agents
        .get(actor)
        .map(|agent| agent.runtime.clone())
        .unwrap_or_default();
    let review = Review {
        review_id: generate_review_id(task_id),
        round,
        reviewer_agent_id: actor.to_string(),
        reviewer_runtime,
        verdict,
        summary: summary.to_string(),
        points: points.to_vec(),
        recorded_at: now.to_string(),
    };
    session_storage::append_review(layout, task_id, &review)?;
    let all_reviews = session_storage::load_reviews(layout, task_id)?;
    Ok(PreparedSubmitReview {
        review,
        all_reviews,
    })
}

pub(super) fn apply_submit_review_in_txn(
    state: &mut SessionState,
    task_id: &str,
    actor: &str,
    prepared: &PreparedSubmitReview,
    now: &str,
) -> Result<(Option<TaskStatus>, Option<TaskStatus>), CliError> {
    validate_submit_review(state, task_id, actor)?;
    let prev_status = state.tasks.get(task_id).map(|task| task.status);
    apply_submit_review(state, task_id, &prepared.review, &prepared.all_reviews, now)?;
    let new_status = state.tasks.get(task_id).map(|task| task.status);
    Ok((prev_status, new_status))
}
