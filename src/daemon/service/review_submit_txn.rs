//! Helper extracted from `review_mutations::submit_review_async` so the
//! mutation wrapper stays under the repo cognitive-complexity cap while
//! still running the append-review + apply-consensus step inside the
//! `SQLite` immediate transaction.

use crate::errors::CliError;
use crate::session::service::{apply_submit_review, generate_review_id, validate_submit_review};
use crate::session::storage as session_storage;
use crate::session::types::{
    Review, ReviewPoint, ReviewVerdict, SessionState, TaskStatus,
};
use crate::workspace::layout::SessionLayout;

#[expect(
    clippy::too_many_arguments,
    reason = "captures full submit_review context; extracted to lower submit_review_async complexity"
)]
pub(super) fn apply_submit_review_in_txn(
    state: &mut SessionState,
    task_id: &str,
    actor: &str,
    verdict: ReviewVerdict,
    summary: &str,
    points: &[ReviewPoint],
    layout: &SessionLayout,
    now: &str,
) -> Result<(Option<TaskStatus>, Option<TaskStatus>, Review), CliError> {
    validate_submit_review(state, task_id, actor)?;
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
    let prev_status = state.tasks.get(task_id).map(|task| task.status);
    apply_submit_review(state, task_id, &review, &all_reviews, now)?;
    let new_status = state.tasks.get(task_id).map(|task| task.status);
    Ok((prev_status, new_status, review))
}
