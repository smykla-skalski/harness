use std::collections::BTreeMap;

use crate::daemon::service::task_board_runtime::external_sync_config_for_repository;
use crate::dependency_updates::{
    DependencyUpdateActionOutcome, DependencyUpdateActionResult, DependencyUpdateItem,
    DependencyUpdateRepositoryLabel, DependencyUpdateTarget, DependencyUpdatesActionResponse,
    DependencyUpdatesApproveRequest, DependencyUpdatesAutoRequest, DependencyUpdatesBodyRequest,
    DependencyUpdatesBodyResponse, DependencyUpdatesBodyUpdateOutcome,
    DependencyUpdatesBodyUpdateRequest, DependencyUpdatesBodyUpdateResponse,
    DependencyUpdatesCacheClearResponse, DependencyUpdatesCommentRequest,
    DependencyUpdatesGitHubClient, DependencyUpdatesLabelRequest, DependencyUpdatesMergeRequest,
    DependencyUpdatesQueryRequest, DependencyUpdatesQueryResponse, DependencyUpdatesRefreshRequest,
    DependencyUpdatesRefreshResponse, DependencyUpdatesRepositoryCatalogRequest,
    DependencyUpdatesRepositoryCatalogResponse, DependencyUpdatesRerunChecksRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::ExternalProvider;
use crate::workspace::utc_now;

#[path = "dependency_updates_cache.rs"]
mod cache_internal;

#[cfg(test)]
pub(super) use cache_internal::apply_refresh_to_items;
use cache_internal::{
    body_cache, cache, cached_body_response, cached_query_response, patch_cached_items,
    patch_cached_repository_labels, store_cached_body_response, store_cached_query_response,
};

#[derive(Clone)]
struct TokenBoundRequest {
    token: String,
    request: DependencyUpdatesQueryRequest,
}

#[derive(Clone)]
struct TokenBoundTargets {
    token: String,
    targets: Vec<DependencyUpdateTarget>,
}

/// Query dependency update pull requests through configured GitHub tokens.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub cannot return the requested update data.
pub async fn query_dependency_updates(
    request: &DependencyUpdatesQueryRequest,
) -> Result<DependencyUpdatesQueryResponse, CliError> {
    request.validate()?;
    let cache_key = request.cache_key();
    if !request.force_refresh
        && let Some(response) = cached_query_response(&cache_key, request.cache_max_age_seconds())
    {
        return Ok(response);
    }

    let segments = token_bound_requests(request)?;
    let mut items_by_key = BTreeMap::new();
    let mut repository_labels: BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>> =
        BTreeMap::new();
    for segment in segments {
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
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
        .collect::<Vec<DependencyUpdateItem>>();
    items.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.repository.cmp(&right.repository))
            .then_with(|| left.number.cmp(&right.number))
    });
    let mut response = DependencyUpdatesQueryResponse::new(items, utc_now());
    response.set_repository_labels(repository_labels);
    store_cached_query_response(cache_key, &response);
    Ok(response)
}

/// List repositories in an organization that can be used for dependency updates.
///
/// # Errors
/// Returns `CliError` when the request is invalid, the GitHub token is missing,
/// or GitHub cannot return the repository catalog.
pub async fn catalog_dependency_update_repositories(
    request: &DependencyUpdatesRepositoryCatalogRequest,
) -> Result<DependencyUpdatesRepositoryCatalogResponse, CliError> {
    request.validate()?;
    let organization = request.normalized_organization();
    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = DependencyUpdatesGitHubClient::new(&token)?;
    let repositories = client
        .catalog_organization_repositories(&organization)
        .await?;
    Ok(DependencyUpdatesRepositoryCatalogResponse {
        organization,
        repositories,
    })
}

/// Approve selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects an approval.
pub async fn approve_dependency_updates(
    request: &DependencyUpdatesApproveRequest,
) -> Result<DependencyUpdatesActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .approve(&DependencyUpdatesApproveRequest {
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
pub async fn comment_on_dependency_updates(
    request: &DependencyUpdatesCommentRequest,
) -> Result<DependencyUpdatesActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .comment(&DependencyUpdatesCommentRequest {
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
pub async fn merge_dependency_updates(
    request: &DependencyUpdatesMergeRequest,
) -> Result<DependencyUpdatesActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .merge(&DependencyUpdatesMergeRequest {
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
pub async fn rerun_dependency_updates_checks(
    request: &DependencyUpdatesRerunChecksRequest,
) -> Result<DependencyUpdatesActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .rerun_checks(&DependencyUpdatesRerunChecksRequest {
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
pub async fn add_label_to_dependency_updates(
    request: &DependencyUpdatesLabelRequest,
) -> Result<DependencyUpdatesActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .add_label(&DependencyUpdatesLabelRequest {
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
pub async fn auto_dependency_updates(
    request: &DependencyUpdatesAutoRequest,
) -> Result<DependencyUpdatesActionResponse, CliError> {
    request.validate()?;
    let eligible_targets = request
        .targets
        .iter()
        .filter(|target| target.is_auto_approvable() || target.is_auto_mergeable())
        .cloned()
        .collect::<Vec<_>>();
    if eligible_targets.is_empty() {
        return Ok(DependencyUpdatesActionResponse {
            summary: "No dependency updates were eligible for auto mode".to_string(),
            results: Vec::new(),
        });
    }

    let mut results = Vec::new();
    for segment in token_bound_targets(&eligible_targets)? {
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .auto_mode(&DependencyUpdatesAutoRequest {
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
pub async fn refresh_dependency_updates(
    request: &DependencyUpdatesRefreshRequest,
) -> Result<DependencyUpdatesRefreshResponse, CliError> {
    request.validate()?;
    let mut items = Vec::new();
    let mut missing = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let ids: Vec<String> = segment
            .targets
            .iter()
            .map(|target| target.pull_request_id.clone())
            .collect();
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
        let fetch = client.fetch_by_ids(&ids).await?;
        items.extend(fetch.items);
        missing.extend(fetch.missing);
        if !fetch.repository_labels.is_empty() {
            patch_cached_repository_labels(&fetch.repository_labels);
        }
    }
    patch_cached_items(&items, &missing);
    Ok(DependencyUpdatesRefreshResponse {
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
pub async fn fetch_dependency_update_body(
    request: &DependencyUpdatesBodyRequest,
) -> Result<DependencyUpdatesBodyResponse, CliError> {
    request.validate()?;
    let cache_key = request.normalized_pull_request_id();
    if !request.force_refresh
        && let Some(response) = cached_body_response(&cache_key, request.cache_max_age_seconds())
    {
        return Ok(response);
    }

    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = DependencyUpdatesGitHubClient::new(&token)?;
    let (body, pr_updated_at) = client.fetch_pull_request_body(&cache_key).await?;
    let response = DependencyUpdatesBodyResponse {
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
pub async fn update_dependency_update_body(
    request: &DependencyUpdatesBodyUpdateRequest,
) -> Result<DependencyUpdatesBodyUpdateResponse, CliError> {
    request.validate()?;
    let pull_request_id = request.normalized_pull_request_id();
    let expected_sha = request.normalized_expected_prior_body_sha256();

    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = DependencyUpdatesGitHubClient::new(&token)?;

    let (current_body, current_updated_at) =
        client.fetch_pull_request_body(&pull_request_id).await?;
    let current_sha = sha256_hex(&current_body);
    let fetched_at = utc_now();

    if current_sha != expected_sha {
        return Ok(DependencyUpdatesBodyUpdateResponse {
            pull_request_id,
            outcome: DependencyUpdatesBodyUpdateOutcome::BodyDrifted,
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
    let response = DependencyUpdatesBodyUpdateResponse {
        pull_request_id: pull_request_id.clone(),
        outcome: DependencyUpdatesBodyUpdateOutcome::Updated,
        current_body: new_body.clone(),
        current_body_sha256: new_sha,
        pr_updated_at: new_updated_at,
        fetched_at: fetched_at.clone(),
    };
    let cached = DependencyUpdatesBodyResponse {
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
pub fn clear_dependency_updates_cache() -> Result<DependencyUpdatesCacheClearResponse, CliError> {
    let mut cache = cache().lock().expect("dependency-updates cache lock");
    let mut cleared_entries = cache.len();
    cache.clear();
    drop(cache);
    let mut body_cache = body_cache()
        .lock()
        .expect("dependency-updates body cache lock");
    cleared_entries += body_cache.len();
    body_cache.clear();
    Ok(DependencyUpdatesCacheClearResponse { cleared_entries })
}

fn token_bound_requests(
    request: &DependencyUpdatesQueryRequest,
) -> Result<Vec<TokenBoundRequest>, CliError> {
    let global_token = github_token(None);
    let mut segments = Vec::new();

    let org_request = request.organization_only_request();
    if !org_request.normalized_organizations().is_empty() {
        let token = global_token
            .clone()
            .ok_or_else(|| missing_token_error(None))?;
        segments.push(TokenBoundRequest {
            token,
            request: org_request,
        });
    }

    let excluded = request.normalized_exclude_repositories();
    for repository in request.normalized_repositories() {
        if excluded.contains(&repository) {
            continue;
        }
        let token = github_token(Some(repository.as_str()))
            .or_else(|| global_token.clone())
            .ok_or_else(|| missing_token_error(Some(repository.as_str())))?;
        segments.push(TokenBoundRequest {
            token,
            request: request.repository_only_request(&repository),
        });
    }

    if segments.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "dependency-updates query resolved to zero token-backed scopes",
        )
        .into());
    }
    Ok(segments)
}

fn token_bound_targets(
    targets: &[DependencyUpdateTarget],
) -> Result<Vec<TokenBoundTargets>, CliError> {
    let global_token = github_token(None);
    let mut grouped = BTreeMap::<String, Vec<DependencyUpdateTarget>>::new();
    for target in targets {
        let token = github_token(Some(target.repository.as_str()))
            .or_else(|| global_token.clone())
            .ok_or_else(|| missing_token_error(Some(target.repository.as_str())))?;
        grouped.entry(token).or_default().push(target.clone());
    }
    Ok(grouped
        .into_iter()
        .map(|(token, targets)| TokenBoundTargets { token, targets })
        .collect())
}

fn github_token(repository: Option<&str>) -> Option<String> {
    external_sync_config_for_repository(repository, &[])
        .token_for(ExternalProvider::GitHub)
        .map(ToString::to_string)
}

fn missing_token_error(repository: Option<&str>) -> CliError {
    match repository {
        Some(repository) => CliErrorKind::workflow_io(format!(
            "dependency-updates requires a GitHub token for '{repository}'. Configure one in Settings > Secrets."
        ))
        .into(),
        None => CliErrorKind::workflow_io(
            "dependency-updates requires a GitHub token. Configure one in Settings > Secrets.",
        )
        .into(),
    }
}

fn action_response(
    summary_prefix: &str,
    results: Vec<DependencyUpdateActionResult>,
) -> DependencyUpdatesActionResponse {
    let applied = results
        .iter()
        .filter(|result| result.outcome == DependencyUpdateActionOutcome::Applied)
        .count();
    let skipped = results
        .iter()
        .filter(|result| result.outcome == DependencyUpdateActionOutcome::Skipped)
        .count();
    let failed = results
        .iter()
        .filter(|result| result.outcome == DependencyUpdateActionOutcome::Failed)
        .count();
    DependencyUpdatesActionResponse {
        summary: format!("{summary_prefix}: {applied} applied, {skipped} skipped, {failed} failed"),
        results,
    }
}

#[cfg(test)]
#[path = "dependency_updates_tests.rs"]
mod tests;
