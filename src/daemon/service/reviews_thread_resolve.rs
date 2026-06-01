//! Service entry point for the review-thread resolve / unresolve
//! write-action. Resolves the GitHub token, delegates the mutation
//! invocation to
//! [`crate::reviews::review_thread_resolve::execute_review_thread_resolve_mutation`],
//! then drains `REVIEWS_TIMELINE_CACHE` for the PR so the
//! next timeline fetch reflects the new `isResolved` state without
//! an extra GitHub round-trip. Mirrors the comment-post + cache-drain
//! pattern from
//! [`crate::daemon::service::reviews::comment_on_reviews`].

use crate::daemon::service::task_board_runtime::external_sync_config_for_repository;
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::review_thread_resolve::{
    ReviewsReviewThreadResolveRequest, ReviewsReviewThreadResolveResponse,
    execute_review_thread_resolve_mutation,
};
use crate::reviews::timeline;
use crate::task_board::external::ExternalProvider;

use super::reviews_github_policy::{ReviewsGitHubMutation, enforce_review_pull_request_policy};

/// Resolve or unresolve a review thread, then drain the per-PR
/// timeline cache so subsequent fetches reflect the new state.
///
/// # Errors
/// Returns `CliError` when the GitHub token is missing or the GraphQL
/// transport fails (propagated from
/// [`execute_review_thread_resolve_mutation`]).
pub async fn set_review_thread_resolved(
    request: &ReviewsReviewThreadResolveRequest,
) -> Result<ReviewsReviewThreadResolveResponse, CliError> {
    enforce_review_pull_request_policy(
        ReviewsGitHubMutation::ReviewThreadResolve,
        &request.pull_request_id,
        None,
        &[],
    )?;
    let token = github_token().ok_or_else(missing_token_error)?;
    let trimmed = token.trim();
    if trimmed.is_empty() {
        return Err(missing_token_error());
    }
    let resolved_after =
        execute_review_thread_resolve_mutation(trimmed, &request.thread_id, request.resolved)
            .await?;
    timeline::drain_pull_request_cache(&request.pull_request_id);
    Ok(ReviewsReviewThreadResolveResponse {
        thread_id: request.thread_id.clone(),
        resolved: resolved_after,
    })
}

fn github_token() -> Option<String> {
    external_sync_config_for_repository(None, &[])
        .token_for(ExternalProvider::GitHub)
        .map(ToString::to_string)
}

fn missing_token_error() -> CliError {
    CliErrorKind::workflow_io(
        "reviews thread-resolve requires a GitHub token. \
         Configure one in Settings > Secrets.",
    )
    .into()
}
