//! Hash-guarded mark-viewed batch endpoint.

use std::collections::BTreeMap;

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::{
    ReviewFileViewedOutcome, ReviewFileViewedState, ReviewFilesViewedResult,
    ReviewsFilesListRequest, ReviewsFilesViewedRequest, ReviewsFilesViewedResponse,
    ReviewsGitHubClient, ViewedMutation, classify_outcome,
};
use crate::workspace::utc_now;

use super::token::{github_token, missing_token_error};

/// Apply hash-guarded mark-viewed mutations across one or more paths.
///
/// Each path is hash-guarded: the daemon first refetches the file list,
/// compares the caller's `expected_prior_state` against the daemon-fresh
/// `viewer_viewed_state`, and either runs the mutation (states match) or
/// reports `Drifted` with the daemon-fresh state so the Monitor can
/// reconcile its optimistic UI.
///
/// # Errors
/// Returns `CliError` for empty payloads or when the GitHub token is
/// missing.
pub async fn mark_review_files_viewed(
    request: &ReviewsFilesViewedRequest,
) -> Result<ReviewsFilesViewedResponse, CliError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews files viewed: pull_request_id must not be empty",
        )
        .into());
    }
    let normalized = request.normalized_paths();
    if normalized.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews files viewed: at least one path is required",
        )
        .into());
    }

    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = ReviewsGitHubClient::new(&token)?;

    // Refetch the file list once so we have a fresh per-path viewer state
    // and can drift-check every requested target without a round-trip per
    // path.
    let current_list = client
        .fetch_pull_request_files(&ReviewsFilesListRequest {
            pull_request_id: pull_request_id.clone(),
            force_refresh: true,
        })
        .await?;
    let current_states: BTreeMap<String, ReviewFileViewedState> = current_list
        .files
        .iter()
        .map(|file| (file.path.clone(), file.viewer_viewed_state))
        .collect();

    let mut results = Vec::with_capacity(normalized.len());
    for target in normalized {
        let current = current_states
            .get(&target.path)
            .copied()
            .unwrap_or(ReviewFileViewedState::Unviewed);
        let outcome = classify_outcome(target.expected_prior_state, current)
            .unwrap_or(ReviewFileViewedOutcome::Drifted);
        if matches!(outcome, ReviewFileViewedOutcome::Drifted) {
            results.push(ReviewFilesViewedResult {
                path: target.path,
                outcome: ReviewFileViewedOutcome::Drifted,
                viewer_viewed_state: current,
            });
            continue;
        }
        match ViewedMutation::decide(current, target.mark_viewed) {
            ViewedMutation::Skip => {
                results.push(ReviewFilesViewedResult {
                    path: target.path,
                    outcome: ReviewFileViewedOutcome::Updated,
                    viewer_viewed_state: current,
                });
            }
            ViewedMutation::Mark | ViewedMutation::Unmark => {
                let next_state = if target.mark_viewed {
                    ReviewFileViewedState::Viewed
                } else {
                    ReviewFileViewedState::Unviewed
                };
                let mutation_result = client
                    .toggle_pull_request_file_viewed(
                        &pull_request_id,
                        &target.path,
                        target.mark_viewed,
                    )
                    .await;
                match mutation_result {
                    Ok(()) => results.push(ReviewFilesViewedResult {
                        path: target.path,
                        outcome: ReviewFileViewedOutcome::Updated,
                        viewer_viewed_state: next_state,
                    }),
                    Err(error) => {
                        tracing::warn!(
                            target = "harness::reviews::files",
                            pull_request_id = pull_request_id,
                            path = target.path,
                            error = %error,
                            "mark_review_files_viewed mutation failed"
                        );
                        results.push(ReviewFilesViewedResult {
                            path: target.path,
                            outcome: ReviewFileViewedOutcome::Failed,
                            viewer_viewed_state: current,
                        });
                    }
                }
            }
        }
    }

    Ok(ReviewsFilesViewedResponse {
        pull_request_id,
        results,
        fetched_at: utc_now(),
    })
}
