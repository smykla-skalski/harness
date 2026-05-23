use std::collections::BTreeMap;

use crate::reviews::{
    ReviewActionOutcome, ReviewActionResult, ReviewItem,
    ReviewRepositoryLabel, ReviewsActionPreviewRequest,
    ReviewsActionPreviewResponse, ReviewsActionResponse,
    ReviewsApproveRequest, ReviewsAutoRequest, ReviewsBodyRequest,
    ReviewsBodyResponse, ReviewsBodyUpdateOutcome,
    ReviewsBodyUpdateRequest, ReviewsBodyUpdateResponse,
    ReviewsCacheClearResponse, ReviewsCapabilitiesResponse,
    ReviewsCommentRequest, ReviewsGitHubClient, ReviewsLabelRequest,
    ReviewsMergeRequest, ReviewsQueryRequest, ReviewsQueryResponse,
    ReviewsRefreshRequest, ReviewsRefreshResponse,
    ReviewsRepositoryCatalogRequest, ReviewsRepositoryCatalogResponse,
    ReviewsRerunChecksRequest,
};
use crate::errors::CliError;
use crate::workspace::utc_now;

#[path = "reviews_cache.rs"]
mod cache_internal;

mod preview;
mod token;

#[cfg(test)]
pub(super) use cache_internal::apply_refresh_to_items;
use cache_internal::{
    body_cache, cache, cached_body_response, cached_query_response, patch_cached_items,
    patch_cached_repository_labels, store_cached_body_response, store_cached_query_response,
};
use preview::{preview_action_target, preview_action_warnings};
use token::{github_token, missing_token_error, token_bound_requests, token_bound_targets};

/// Query dependency update pull requests through configured GitHub tokens.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub cannot return the requested update data.
pub async fn query_reviews(
    request: &ReviewsQueryRequest,
) -> Result<ReviewsQueryResponse, CliError> {
    request.validate()?;
    let cache_key = request.cache_key();
    if !request.force_refresh
        && let Some(response) = cached_query_response(&cache_key, request.cache_max_age_seconds())
    {
        return Ok(response);
    }

    let segments = token_bound_requests(request)?;
    let mut items_by_key = BTreeMap::new();
    let mut repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>> =
        BTreeMap::new();
    let mut viewer_login: Option<String> = None;
    for segment in segments {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        if viewer_login.is_none() {
            // Resolve the viewer once across token segments. Same-token
            // segments share a login; cross-token splits are rare and
            // the first resolved login matches the token whose PRs
            // dominate the response in practice.
            viewer_login = client.fetch_viewer_login().await;
        }
        let fetch = client.fetch_updates(&segment.request).await?;
        for item in fetch.items {
            items_by_key
                .entry(format!("{}#{}", item.repository, item.number))
                .or_insert(item);
        }
        for (repository, labels) in fetch.repository_labels {
            let entry = repository_labels.entry(repository).or_default();
            if entry.is_empty() && !labels.is_empty() {
                *entry = labels;
            }
        }
    }

    let mut items = items_by_key
        .into_values()
        .collect::<Vec<ReviewItem>>();
    items.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.repository.cmp(&right.repository))
            .then_with(|| left.number.cmp(&right.number))
    });
    let mut response = ReviewsQueryResponse::new(items, utc_now());
    response.set_repository_labels(repository_labels);
    response.set_viewer_login(viewer_login);
    store_cached_query_response(cache_key, &response);
    Ok(response)
}

/// List repositories in an organization that can be used for dependency updates.
///
/// # Errors
/// Returns `CliError` when the request is invalid, the GitHub token is missing,
/// or GitHub cannot return the repository catalog.
pub async fn catalog_review_repositories(
    request: &ReviewsRepositoryCatalogRequest,
) -> Result<ReviewsRepositoryCatalogResponse, CliError> {
    request.validate()?;
    let organization = request.normalized_organization();
    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = ReviewsGitHubClient::new(&token)?;
    let repositories = client
        .catalog_organization_repositories(&organization)
        .await?;
    Ok(ReviewsRepositoryCatalogResponse {
        organization,
        repositories,
    })
}

/// Return the dependency-update daemon contract supported by this process.
///
/// # Errors
/// This function currently does not return operational errors.
pub fn reviews_capabilities() -> Result<ReviewsCapabilitiesResponse, CliError>
{
    Ok(ReviewsCapabilitiesResponse::current())
}

/// Preview which dependency-update targets a daemon action would affect.
///
/// # Errors
/// Returns `CliError` when the request is malformed. Missing repository tokens
/// are represented per target so the UI can still explain the rest of the
/// selection.
pub fn preview_review_action(
    request: &ReviewsActionPreviewRequest,
) -> Result<ReviewsActionPreviewResponse, CliError> {
    request.validate()?;
    let targets = request
        .targets
        .iter()
        .map(|target| preview_action_target(request.action, target))
        .collect::<Vec<_>>();
    let actionable_count = targets.iter().filter(|target| target.eligible).count();
    let skipped_count = targets.len().saturating_sub(actionable_count);
    let warnings = preview_action_warnings(request.action, &request.targets);
    Ok(ReviewsActionPreviewResponse {
        action: request.action,
        capabilities: ReviewsCapabilitiesResponse::current(),
        total_count: request.targets.len(),
        actionable_count,
        skipped_count,
        warnings,
        targets,
    })
}

/// Approve selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects an approval.
pub async fn approve_reviews(
    request: &ReviewsApproveRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .approve(&ReviewsApproveRequest {
                    targets: segment.targets,
                })
                .await?,
        );
    }
    Ok(action_response("Approved dependency updates", results))
}

/// Post a comment on each selected dependency update pull request. Used to
/// nudge bots like Renovate (`@renovatebot rebase`) and Dependabot
/// (`@dependabot recreate`) to recreate their PR head.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects the comment write.
pub async fn comment_on_reviews(
    request: &ReviewsCommentRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .comment(&ReviewsCommentRequest {
                    targets: segment.targets,
                    body: request.body.clone(),
                })
                .await?,
        );
    }
    Ok(action_response("Posted dependency update comment", results))
}

/// Merge selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects a merge.
pub async fn merge_reviews(
    request: &ReviewsMergeRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .merge(&ReviewsMergeRequest {
                    targets: segment.targets,
                    method: request.method,
                })
                .await?,
        );
    }
    Ok(action_response("Merged dependency updates", results))
}

/// Rerun checks for selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects the check rerun.
pub async fn rerun_reviews_checks(
    request: &ReviewsRerunChecksRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .rerun_checks(&ReviewsRerunChecksRequest {
                    targets: segment.targets,
                })
                .await?,
        );
    }
    Ok(action_response("Reran dependency update checks", results))
}

/// Add a label to selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects the label update.
pub async fn add_label_to_reviews(
    request: &ReviewsLabelRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .add_label(&ReviewsLabelRequest {
                    targets: segment.targets,
                    label: request.label.clone(),
                })
                .await?,
        );
    }
    Ok(action_response("Labeled dependency updates", results))
}

/// Apply automatic approve or merge actions to eligible dependency updates.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects an automatic action.
pub async fn auto_reviews(
    request: &ReviewsAutoRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    let eligible_targets = request
        .targets
        .iter()
        .filter(|target| target.is_auto_approvable() || target.is_auto_mergeable())
        .cloned()
        .collect::<Vec<_>>();
    if eligible_targets.is_empty() {
        return Ok(ReviewsActionResponse {
            summary: "No dependency updates were eligible for auto mode".to_string(),
            results: Vec::new(),
        });
    }

    let mut results = Vec::new();
    for segment in token_bound_targets(&eligible_targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .auto_mode(&ReviewsAutoRequest {
                    targets: segment.targets,
                    method: request.method,
                })
                .await?,
        );
    }
    Ok(action_response("Auto mode finished", results))
}

/// Re-fetch a focused list of dependency update pull requests by GraphQL ID,
/// patching matching cache entries in place and returning the refreshed items.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub cannot return the requested pull requests.
pub async fn refresh_reviews(
    request: &ReviewsRefreshRequest,
) -> Result<ReviewsRefreshResponse, CliError> {
    request.validate()?;
    let mut items = Vec::new();
    let mut missing = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let ids: Vec<String> = segment
            .targets
            .iter()
            .map(|target| target.pull_request_id.clone())
            .collect();
        let client = ReviewsGitHubClient::new(&segment.token)?;
        let fetch = client.fetch_by_ids(&ids).await?;
        items.extend(fetch.items);
        missing.extend(fetch.missing);
        if !fetch.repository_labels.is_empty() {
            patch_cached_repository_labels(&fetch.repository_labels);
        }
    }
    patch_cached_items(&items, &missing);
    Ok(ReviewsRefreshResponse {
        fetched_at: utc_now(),
        items,
        missing_pull_request_ids: missing,
    })
}

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

/// Clear the in-memory dependency updates query cache (list + body).
///
/// # Errors
/// This function currently does not return operational errors.
///
/// # Panics
/// Panics if either dependency updates cache mutex is poisoned.
pub fn clear_reviews_cache() -> Result<ReviewsCacheClearResponse, CliError> {
    let mut cache = cache().lock().expect("reviews cache lock");
    let mut cleared_entries = cache.len();
    cache.clear();
    drop(cache);
    let mut body_cache = body_cache()
        .lock()
        .expect("reviews body cache lock");
    cleared_entries += body_cache.len();
    body_cache.clear();
    Ok(ReviewsCacheClearResponse { cleared_entries })
}

fn action_response(
    summary_prefix: &str,
    results: Vec<ReviewActionResult>,
) -> ReviewsActionResponse {
    let applied = results
        .iter()
        .filter(|result| result.outcome == ReviewActionOutcome::Applied)
        .count();
    let skipped = results
        .iter()
        .filter(|result| result.outcome == ReviewActionOutcome::Skipped)
        .count();
    let failed = results
        .iter()
        .filter(|result| result.outcome == ReviewActionOutcome::Failed)
        .count();
    ReviewsActionResponse {
        summary: format!("{summary_prefix}: {applied} applied, {skipped} skipped, {failed} failed"),
        results,
    }
}

#[cfg(test)]
#[path = "reviews_tests.rs"]
mod tests;
