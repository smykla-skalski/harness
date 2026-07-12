use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service::observe_async_db;
use crate::errors::{CliError, CliErrorKind};
use crate::github_api::retry_stable_read;
use crate::reviews::{
    ReviewActionPreviewKind, ReviewItem, ReviewRepositoryLabel, ReviewsActionPreviewRequest,
    ReviewsActionPreviewResponse, ReviewsActionResponse, ReviewsAutoRequest,
    ReviewsCacheClearResponse, ReviewsCapabilitiesResponse, ReviewsGitHubClient,
    ReviewsPolicyPreviewRequest, ReviewsPolicyRunStartRequest, ReviewsPolicyTrigger,
    ReviewsQueryRequest, ReviewsQueryResponse, ReviewsRepositoryCatalogRequest,
    ReviewsRepositoryCatalogResponse,
};
use crate::workspace::utc_now;

#[path = "reviews_cache.rs"]
mod cache_internal;

mod actions;
mod auto_policy;
mod body;
mod github_projection;
pub(crate) mod policy;
mod policy_audit;
mod policy_enrichment;
pub(crate) mod policy_event_inbox;
pub(crate) mod policy_executor;
pub(crate) mod policy_history;
pub(crate) mod policy_mapping;
mod policy_plan;
pub(crate) mod policy_resume;
mod preview;
mod refresh;
mod resolve;
mod token;

pub use actions::{
    add_label_to_reviews, add_review_file_comment, approve_reviews, comment_on_reviews,
    merge_reviews, request_review_for_reviews, rerun_reviews_checks,
};
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
    body_cache, cache, cached_query_source_at_revision, store_cached_query_response_at_revision,
};
#[cfg(test)]
use cache_internal::{
    cached_body_response, cached_query_response, store_cached_body_response,
    store_cached_query_response,
};
pub use policy::{preview_reviews_policy, reviews_policy_status, start_reviews_policy_run};
pub(crate) use policy::{
    preview_reviews_policy_with_audit_db, reviews_policy_status_with_audit_db,
    start_reviews_policy_run_with_audit_db,
};
use policy_enrichment::enrich_policy_target_for_execution;
pub use policy_history::reviews_policy_history;
pub(crate) use policy_history::reviews_policy_history_with_audit_db;
use preview::{preview_action_target, preview_action_warnings};
pub use refresh::refresh_reviews;
pub use resolve::resolve_review_pull_requests;
use token::{github_token, missing_token_error, token_bound_requests};

/// Query dependency update pull requests through configured GitHub tokens.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// GitHub cannot return the requested update data, or concurrent writes prevent
/// a stable fetch-and-projection attempt.
pub async fn query_reviews(
    request: &ReviewsQueryRequest,
) -> Result<ReviewsQueryResponse, CliError> {
    let database = observe_async_db();
    let response = query_reviews_with_database(request, database.as_deref()).await?;
    policy_event_inbox::resume_waiting_reviews_policy_runs(&response.items).await;
    policy::start_background_reviews_policy_runs(&response.items).await;
    Ok(response)
}

#[derive(Clone)]
pub(crate) struct ReviewsQuerySource {
    pub(crate) response: ReviewsQueryResponse,
    pub(crate) github_data_revision: u64,
    authoritative_viewer_keys: HashSet<String>,
}

pub(crate) async fn query_reviews_repositories_source(
    request: &ReviewsQueryRequest,
) -> Result<ReviewsQuerySource, CliError> {
    request.validate()?;
    let repository_requests = request
        .normalized_repositories()
        .into_iter()
        .map(|repository| request.repository_only_request(&repository))
        .collect::<Vec<_>>();
    if repository_requests.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews repository source requires at least one repository",
        )
        .into());
    }
    retry_stable_read("reviews.query.repository_sources", |revision| {
        let repository_requests = repository_requests.clone();
        async move {
            let mut accumulator = ReviewsFetchAccumulator::default();
            let mut all_from_cache = true;
            for repository_request in repository_requests {
                let source = load_reviews_source_once(&repository_request, revision).await?;
                all_from_cache &= source.response.from_cache;
                accumulator.merge_source(source);
            }
            let (mut response, authoritative_viewer_keys) = response_from_fetch(accumulator);
            response.from_cache = all_from_cache;
            Ok::<_, CliError>(ReviewsQuerySource {
                response,
                github_data_revision: revision,
                authoritative_viewer_keys,
            })
        }
    })
    .await
    .map(|(source, _)| source)
}

async fn query_reviews_with_database(
    request: &ReviewsQueryRequest,
    database: Option<&AsyncDaemonDb>,
) -> Result<ReviewsQueryResponse, CliError> {
    request.validate()?;
    let (source, _) = retry_stable_read("reviews.query", |revision| async move {
        let source = load_reviews_source_once(request, revision).await?;
        github_projection::reconcile_task_board(
            database,
            &source.response.items,
            &source.authoritative_viewer_keys,
            github_projection::MissingReviewResolution::ExactActiveImports(request.clone()),
            request.backport_detection_enabled,
            &request.backport_patterns,
            revision,
        )
        .await?;
        Ok::<_, CliError>(source)
    })
    .await?;
    Ok(source.response)
}

async fn load_reviews_source_once(
    request: &ReviewsQueryRequest,
    github_data_revision: u64,
) -> Result<ReviewsQuerySource, CliError> {
    let cache_key = request.cache_key();
    if !request.force_refresh
        && let Some((response, authoritative_viewer_keys)) = cached_query_source_at_revision(
            &cache_key,
            request.cache_max_age_seconds(),
            github_data_revision,
        )
    {
        return Ok(ReviewsQuerySource {
            response,
            github_data_revision,
            authoritative_viewer_keys,
        });
    }
    let fetched = fetch_reviews_across_segments(request).await?;
    let (response, authoritative_viewer_keys) = response_from_fetch(fetched);
    store_cached_query_response_at_revision(
        cache_key,
        &response,
        &authoritative_viewer_keys,
        github_data_revision,
    );
    Ok(ReviewsQuerySource {
        response,
        github_data_revision,
        authoritative_viewer_keys,
    })
}

fn response_from_fetch(
    fetched: ReviewsFetchAccumulator,
) -> (ReviewsQueryResponse, HashSet<String>) {
    let ReviewsFetchAccumulator {
        items_by_key,
        repository_labels,
        viewer_login,
        authoritative_viewer_keys,
    } = fetched;
    let mut items = items_by_key.into_values().collect::<Vec<ReviewItem>>();
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
    (response, authoritative_viewer_keys)
}

/// Accumulated fetch results across every token segment of a reviews query.
#[derive(Default)]
struct ReviewsFetchAccumulator {
    items_by_key: BTreeMap<String, ReviewItem>,
    repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    viewer_login: Option<String>,
    authoritative_viewer_keys: HashSet<String>,
}

impl ReviewsFetchAccumulator {
    fn merge_source(&mut self, source: ReviewsQuerySource) {
        if self.viewer_login.is_none() {
            self.viewer_login.clone_from(&source.response.viewer_login);
        }
        for item in source.response.items {
            let key = review_item_key(&item);
            if source.authoritative_viewer_keys.contains(&key) {
                self.authoritative_viewer_keys.insert(key.clone());
                self.items_by_key.insert(key, item);
            } else {
                self.items_by_key.entry(key).or_insert(item);
            }
        }
        merge_segment_repository_labels(
            &mut self.repository_labels,
            source.response.repository_labels,
        );
    }
}

/// Fetch updates for each token segment, deduplicating items by repository and
/// number and resolving the viewer independently for each token.
async fn fetch_reviews_across_segments(
    request: &ReviewsQueryRequest,
) -> Result<ReviewsFetchAccumulator, CliError> {
    let segments = token_bound_requests(request)?;
    let mut items_by_key = BTreeMap::new();
    let mut repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
    let mut viewer_login: Option<String> = None;
    let mut authoritative_viewer_keys = HashSet::new();
    for segment in segments {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        let segment_viewer_login = client.fetch_viewer_login().await;
        if viewer_login.is_none() {
            viewer_login.clone_from(&segment_viewer_login);
        }
        let fetch = client
            .fetch_updates(&segment.request, segment_viewer_login.as_deref())
            .await?;
        for item in fetch.items {
            let key = review_item_key(&item);
            if segment_viewer_login.is_some() {
                authoritative_viewer_keys.insert(key.clone());
                items_by_key.insert(key, item);
            } else {
                items_by_key.entry(key).or_insert(item);
            }
        }
        merge_segment_repository_labels(&mut repository_labels, fetch.repository_labels);
    }
    Ok(ReviewsFetchAccumulator {
        items_by_key,
        repository_labels,
        viewer_login,
        authoritative_viewer_keys,
    })
}

fn review_item_key(item: &ReviewItem) -> String {
    format!("{}#{}", item.repository.to_ascii_lowercase(), item.number)
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
pub async fn preview_review_action(
    request: &ReviewsActionPreviewRequest,
) -> Result<ReviewsActionPreviewResponse, CliError> {
    preview_review_action_with_audit_db(request, observe_async_db()).await
}

pub(crate) async fn preview_review_action_with_audit_db(
    request: &ReviewsActionPreviewRequest,
    database: Option<Arc<AsyncDaemonDb>>,
) -> Result<ReviewsActionPreviewResponse, CliError> {
    request.validate()?;
    if request.action == ReviewActionPreviewKind::Auto {
        return preview_auto_review_action(request, database).await;
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

/// Apply automatic approve or merge actions to eligible dependency updates.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects an automatic action.
pub async fn auto_reviews(request: &ReviewsAutoRequest) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    let mut results = Vec::new();
    for target in &request.targets {
        let target = enrich_policy_target_for_execution(target).await;
        let preview = preview_reviews_policy(&ReviewsPolicyPreviewRequest {
            workflow_id: String::new(),
            target: target.clone(),
            method: request.method,
        })
        .await?;
        if !preview.eligible {
            results.push(skipped_auto_policy_result(&target, &preview));
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
            Ok(run) => results.extend(auto_policy_results_from_run(&target, &preview, &run)),
            Err(error) => results.push(failed_auto_policy_result(
                &target,
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
