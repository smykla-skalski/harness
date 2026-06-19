use std::collections::BTreeMap;

use crate::errors::CliError;
use crate::reviews::timeline;
use crate::reviews::{
    ReviewActionPreviewKind, ReviewItem, ReviewRepositoryLabel, ReviewsActionPreviewRequest,
    ReviewsActionPreviewResponse, ReviewsActionResponse, ReviewsApproveRequest, ReviewsAutoRequest,
    ReviewsCacheClearResponse, ReviewsCapabilitiesResponse, ReviewsCommentRequest,
    ReviewsFileCommentRequest, ReviewsFileCommentResponse, ReviewsGitHubClient,
    ReviewsLabelRequest, ReviewsMergeRequest, ReviewsPolicyPreviewRequest,
    ReviewsPolicyRunStartRequest, ReviewsPolicyTrigger, ReviewsQueryRequest, ReviewsQueryResponse,
    ReviewsRefreshRequest, ReviewsRefreshResponse, ReviewsRepositoryCatalogRequest,
    ReviewsRepositoryCatalogResponse, ReviewsRequestReviewRequest, ReviewsRerunChecksRequest,
};
use crate::workspace::utc_now;

use super::reviews_github_policy::{
    ReviewsGitHubMutation, enforce_review_file_comment_policy, enforce_review_targets_policy,
};

#[path = "reviews_cache.rs"]
mod cache_internal;

mod auto_policy;
mod body;
pub(crate) mod policy;
mod policy_audit;
pub(crate) mod policy_event_inbox;
pub(crate) mod policy_executor;
pub(crate) mod policy_history;
pub(crate) mod policy_mapping;
pub(crate) mod policy_resume;
mod preview;
mod token;

use auto_policy::{
    action_response, auto_policy_results_from_run, failed_auto_policy_result,
    preview_auto_review_action, skipped_auto_policy_result,
};
#[cfg(test)]
use body::sha256_hex;
pub use body::{fetch_review_body, update_review_body};
#[cfg(test)]
pub(super) use cache_internal::apply_refresh_to_items;
use cache_internal::{
    body_cache, cache, cached_query_response, patch_cached_items, patch_cached_repository_labels,
    store_cached_query_response,
};
#[cfg(test)]
use cache_internal::{cached_body_response, store_cached_body_response};
pub(crate) use policy::start_reviews_policy_run_with_audit_db;
pub use policy::{preview_reviews_policy, reviews_policy_status, start_reviews_policy_run};
pub use policy_history::reviews_policy_history;
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

    let fetched = fetch_reviews_across_segments(request).await?;

    let mut items = fetched
        .items_by_key
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
    response.set_repository_labels(fetched.repository_labels);
    response.set_viewer_login(fetched.viewer_login);
    store_cached_query_response(cache_key, &response);
    policy_event_inbox::resume_waiting_reviews_policy_runs(&response.items).await;
    policy::start_background_reviews_policy_runs(&response.items).await;
    Ok(response)
}

/// Accumulated fetch results across every token segment of a reviews query.
struct ReviewsFetchAccumulator {
    items_by_key: BTreeMap<String, ReviewItem>,
    repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    viewer_login: Option<String>,
}

/// Fetch updates for each token segment, deduplicating items by repository and
/// number and resolving the viewer login once across segments.
async fn fetch_reviews_across_segments(
    request: &ReviewsQueryRequest,
) -> Result<ReviewsFetchAccumulator, CliError> {
    let segments = token_bound_requests(request)?;
    let mut items_by_key = BTreeMap::new();
    let mut repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
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
        let fetch = client
            .fetch_updates(&segment.request, viewer_login.as_deref())
            .await?;
        for item in fetch.items {
            items_by_key
                .entry(format!("{}#{}", item.repository, item.number))
                .or_insert(item);
        }
        merge_segment_repository_labels(&mut repository_labels, fetch.repository_labels);
    }
    Ok(ReviewsFetchAccumulator {
        items_by_key,
        repository_labels,
        viewer_login,
    })
}

fn merge_segment_repository_labels(
    repository_labels: &mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    segment_labels: impl IntoIterator<Item = (String, Vec<ReviewRepositoryLabel>)>,
) {
    for (repository, labels) in segment_labels {
        let entry = repository_labels.entry(repository).or_default();
        if entry.is_empty() && !labels.is_empty() {
            *entry = labels;
        }
    }
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
pub fn reviews_capabilities() -> Result<ReviewsCapabilitiesResponse, CliError> {
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
    if request.action == ReviewActionPreviewKind::Auto {
        return preview_auto_review_action(request);
    }
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
    enforce_review_targets_policy(ReviewsGitHubMutation::Approve, &request.targets)?;
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
    enforce_review_targets_policy(ReviewsGitHubMutation::Comment, &request.targets)?;
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

/// Add or reply to an inline pull-request file review comment.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a GitHub token is missing,
/// or GitHub rejects the inline comment mutation.
pub async fn add_review_file_comment(
    request: &ReviewsFileCommentRequest,
) -> Result<ReviewsFileCommentResponse, CliError> {
    request.validate()?;
    enforce_review_file_comment_policy(request)?;
    let repository = request.repository.as_deref();
    let token = github_token(repository)
        .or_else(|| github_token(None))
        .ok_or_else(|| missing_token_error(repository))?;
    let client = ReviewsGitHubClient::new(&token)?;
    let response = client.add_file_comment(request).await?;
    timeline::drain_pull_request_cache(&request.pull_request_id);
    Ok(response)
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
    enforce_review_targets_policy(ReviewsGitHubMutation::Merge, &request.targets)?;
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
    enforce_review_targets_policy(ReviewsGitHubMutation::RerunChecks, &request.targets)?;
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
    enforce_review_targets_policy(ReviewsGitHubMutation::AddLabel, &request.targets)?;
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

/// Re-request a fresh review from a specific GitHub login on each target
/// pull request. Reuses the configured token per repository.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects the request-review write.
pub async fn request_review_for_reviews(
    request: &ReviewsRequestReviewRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    enforce_review_targets_policy(ReviewsGitHubMutation::RequestReview, &request.targets)?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .request_review(&ReviewsRequestReviewRequest {
                    targets: segment.targets,
                    reviewer_login: request.reviewer_login.clone(),
                })
                .await?,
        );
    }
    Ok(action_response("Re-requested review", results))
}

/// Apply automatic approve or merge actions to eligible dependency updates.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects an automatic action.
pub async fn auto_reviews(request: &ReviewsAutoRequest) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for target in &request.targets {
        let preview = preview_reviews_policy(&ReviewsPolicyPreviewRequest {
            workflow_id: String::new(),
            target: target.clone(),
            method: request.method,
        })?;
        if !preview.eligible {
            results.push(skipped_auto_policy_result(target, &preview));
            continue;
        }

        match start_reviews_policy_run(&ReviewsPolicyRunStartRequest {
            workflow_id: String::new(),
            target: target.clone(),
            method: request.method,
            trigger: ReviewsPolicyTrigger::Manual,
        })
        .await
        {
            Ok(run) => results.extend(auto_policy_results_from_run(target, &preview, &run)),
            Err(error) => results.push(failed_auto_policy_result(
                target,
                &preview,
                &error.to_string(),
            )),
        }
    }

    if results.is_empty() {
        return Ok(ReviewsActionResponse {
            summary: "No dependency updates were eligible for auto mode".to_string(),
            results,
        });
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
        let viewer_login = client.fetch_viewer_login().await;
        let fetch = client
            .fetch_by_ids(&ids, request, viewer_login.as_deref())
            .await?;
        items.extend(fetch.items);
        missing.extend(fetch.missing);
        if !fetch.repository_labels.is_empty() {
            patch_cached_repository_labels(&fetch.repository_labels);
        }
    }
    patch_cached_items(&items, &missing);
    policy_event_inbox::resume_waiting_reviews_policy_runs(&items).await;
    policy::start_background_reviews_policy_runs(&items).await;
    Ok(ReviewsRefreshResponse {
        fetched_at: utc_now(),
        items,
        missing_pull_request_ids: missing,
    })
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
    let mut body_cache = body_cache().lock().expect("reviews body cache lock");
    cleared_entries += body_cache.len();
    body_cache.clear();
    Ok(ReviewsCacheClearResponse { cleared_entries })
}

#[cfg(test)]
#[path = "reviews_tests.rs"]
mod tests;
