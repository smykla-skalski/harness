use crate::errors::CliError;
use crate::reviews::{
    ReviewsBodyRequest, ReviewsBodyResponse, ReviewsBodyUpdateOutcome, ReviewsBodyUpdateRequest,
    ReviewsBodyUpdateResponse, ReviewsGitHubClient,
};
use crate::workspace::utc_now;

use super::cache_internal::{cached_body_response, store_cached_body_response};
use super::token::{github_token, missing_token_error};

/// Fetch the description body for a single dependency update pull request.
///
/// Caches per `pull_request_id` for `cache_max_age_seconds` to keep repeated
/// detail-pane opens cheap. The bulk list query intentionally omits `body`.
///
/// # Errors
/// Returns `CliError` when the request is invalid, the GitHub token is
/// missing, or GitHub cannot return the pull request.
pub async fn fetch_review_body(
    request: &ReviewsBodyRequest,
) -> Result<ReviewsBodyResponse, CliError> {
    request.validate()?;
    let cache_key = request.normalized_pull_request_id();
    if !request.force_refresh
        && let Some(response) = cached_body_response(&cache_key, request.cache_max_age_seconds())
    {
        return Ok(response);
    }

    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = ReviewsGitHubClient::new(&token)?;
    let (body, pr_updated_at) = client.fetch_pull_request_body(&cache_key).await?;
    let response = ReviewsBodyResponse {
        pull_request_id: cache_key.clone(),
        body,
        pr_updated_at,
        fetched_at: utc_now(),
        from_cache: false,
    };
    store_cached_body_response(cache_key, &response);
    Ok(response)
}

/// Post a new pull-request body to GitHub after verifying the caller had
/// observed the latest body.
///
/// Re-fetches the current body (bypassing the daemon cache) and compares its
/// SHA-256 with `expected_prior_body_sha256`. On match the new body is sent via
/// the `updatePullRequest` mutation and the body cache is written through. On
/// mismatch the response carries the current body so the caller can re-render
/// without writing.
///
/// # Errors
/// Returns `CliError` when the request is invalid, the GitHub token is
/// missing, or GitHub cannot return or accept the pull request body.
pub async fn update_review_body(
    request: &ReviewsBodyUpdateRequest,
) -> Result<ReviewsBodyUpdateResponse, CliError> {
    request.validate()?;
    let pull_request_id = request.normalized_pull_request_id();
    let expected_sha = request.normalized_expected_prior_body_sha256();

    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = ReviewsGitHubClient::new(&token)?;

    let (current_body, current_updated_at) =
        client.fetch_pull_request_body(&pull_request_id).await?;
    let current_sha = sha256_hex(&current_body);
    let fetched_at = utc_now();

    if current_sha != expected_sha {
        return Ok(ReviewsBodyUpdateResponse {
            pull_request_id,
            outcome: ReviewsBodyUpdateOutcome::BodyDrifted,
            current_body,
            current_body_sha256: current_sha,
            pr_updated_at: current_updated_at,
            fetched_at,
        });
    }

    let (new_body, new_updated_at) = client
        .update_pull_request_body(&pull_request_id, &request.new_body)
        .await?;
    let new_sha = sha256_hex(&new_body);
    let response = ReviewsBodyUpdateResponse {
        pull_request_id: pull_request_id.clone(),
        outcome: ReviewsBodyUpdateOutcome::Updated,
        current_body: new_body.clone(),
        current_body_sha256: new_sha,
        pr_updated_at: new_updated_at,
        fetched_at: fetched_at.clone(),
    };
    let cached = ReviewsBodyResponse {
        pull_request_id: pull_request_id.clone(),
        body: new_body,
        pr_updated_at: new_updated_at,
        fetched_at,
        from_cache: false,
    };
    store_cached_body_response(pull_request_id, &cached);
    Ok(response)
}

pub(crate) fn sha256_hex(input: &str) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(input.as_bytes()))
}
