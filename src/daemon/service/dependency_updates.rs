use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use crate::daemon::service::task_board_runtime::external_sync_config_for_repository;
use crate::dependency_updates::{
    DependencyUpdateActionOutcome, DependencyUpdateActionResult, DependencyUpdateItem,
    DependencyUpdateTarget, DependencyUpdatesActionResponse, DependencyUpdatesApproveRequest,
    DependencyUpdatesAutoRequest, DependencyUpdatesCacheClearResponse,
    DependencyUpdatesGitHubClient, DependencyUpdatesLabelRequest,
    DependencyUpdatesMergeRequest, DependencyUpdatesQueryRequest, DependencyUpdatesQueryResponse,
    DependencyUpdatesRerunChecksRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::ExternalProvider;
use crate::workspace::utc_now;

static DEPENDENCY_UPDATES_CACHE: OnceLock<Mutex<BTreeMap<String, CachedDependencyUpdates>>> =
    OnceLock::new();

#[derive(Clone)]
struct CachedDependencyUpdates {
    stored_at: Instant,
    response: DependencyUpdatesQueryResponse,
}

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
    for segment in segments {
        let client = DependencyUpdatesGitHubClient::new(&segment.token)?;
        for item in client.fetch_updates(&segment.request).await? {
            items_by_key
                .entry(format!("{}#{}", item.repository, item.number))
                .or_insert(item);
        }
    }

    let mut items = items_by_key.into_values().collect::<Vec<DependencyUpdateItem>>();
    items.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.repository.cmp(&right.repository))
            .then_with(|| left.number.cmp(&right.number))
    });
    let response = DependencyUpdatesQueryResponse::new(items, utc_now());
    store_cached_query_response(cache_key, &response);
    Ok(response)
}

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

pub fn clear_dependency_updates_cache() -> Result<DependencyUpdatesCacheClearResponse, CliError> {
    let mut cache = cache().lock().expect("dependency-updates cache lock");
    let cleared_entries = cache.len();
    cache.clear();
    Ok(DependencyUpdatesCacheClearResponse { cleared_entries })
}

fn token_bound_requests(
    request: &DependencyUpdatesQueryRequest,
) -> Result<Vec<TokenBoundRequest>, CliError> {
    let global_token = github_token(None);
    let mut segments = Vec::new();

    let org_request = request.organization_only_request();
    if !org_request.normalized_organizations().is_empty() {
        let token = global_token.clone().ok_or_else(|| missing_token_error(None))?;
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

fn token_bound_targets(targets: &[DependencyUpdateTarget]) -> Result<Vec<TokenBoundTargets>, CliError> {
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

fn cache() -> &'static Mutex<BTreeMap<String, CachedDependencyUpdates>> {
    DEPENDENCY_UPDATES_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

fn cached_query_response(
    cache_key: &str,
    max_age_seconds: u64,
) -> Option<DependencyUpdatesQueryResponse> {
    let cache = cache().lock().expect("dependency-updates cache lock");
    let entry = cache.get(cache_key)?;
    if entry.stored_at.elapsed().as_secs() > max_age_seconds {
        return None;
    }
    let mut response = entry.response.clone();
    response.from_cache = true;
    Some(response)
}

fn store_cached_query_response(cache_key: String, response: &DependencyUpdatesQueryResponse) {
    let mut cache = cache().lock().expect("dependency-updates cache lock");
    cache.insert(
        cache_key,
        CachedDependencyUpdates {
            stored_at: Instant::now(),
            response: response.clone(),
        },
    );
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
