use std::collections::{BTreeMap, HashSet};

use crate::errors::CliError;
use crate::github_api::{
    GitHubProtectedClient, GitHubPullRequestSnapshot, retry_stable_read, stable_data_revision_guard,
};
use crate::reviews::{
    ReviewItem, ReviewRepositoryLabel, ReviewTarget, ReviewsGitHubClient, ReviewsRefreshRequest,
    ReviewsRefreshResponse,
};
use crate::task_board::reconcile_review_item_from_snapshots;
use crate::workspace::utc_now;

use super::super::db::AsyncDaemonDb;
use super::cache_internal::{patch_cached_items, patch_cached_repository_labels};
use super::token::token_bound_targets;
use super::{
    github_projection, merge_segment_repository_labels, policy, policy_event_inbox, review_item_key,
};
use crate::daemon::service::observe_async_db;

/// Re-fetch a focused list of dependency update pull requests by GraphQL ID,
/// patching matching cache entries in place and returning the refreshed items.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// GitHub cannot return the requested pull requests, or concurrent writes
/// prevent a stable fetch-and-projection attempt.
pub async fn refresh_reviews(
    request: &ReviewsRefreshRequest,
) -> Result<ReviewsRefreshResponse, CliError> {
    request.validate()?;
    let database = observe_async_db();
    let (fetched, _) = retry_stable_read("reviews.refresh", |revision| {
        let database = database.clone();
        async move {
            let fetched = fetch_reviews_refresh_once(request).await?;
            let projected = github_projection::reconcile_task_board(
                database.as_deref(),
                &fetched.items,
                &fetched.authoritative_viewer_keys,
                github_projection::MissingReviewResolution::ProvidedSnapshotsOnly,
                request.backport_detection_enabled,
                &request.backport_patterns,
                revision,
            )
            .await?;
            if projected {
                reconcile_targeted_missing_task_board_reviews(
                    database.as_deref(),
                    request,
                    &fetched.missing,
                    revision,
                )
                .await?;
            }
            Ok::<_, CliError>(fetched)
        }
    })
    .await?;
    if !fetched.repository_labels.is_empty() {
        patch_cached_repository_labels(&fetched.repository_labels);
    }
    patch_cached_items(
        &fetched.items,
        &fetched.missing,
        &fetched.authoritative_viewer_keys,
    );
    policy_event_inbox::resume_waiting_reviews_policy_runs(&fetched.items).await;
    policy::start_background_reviews_policy_runs(&fetched.items).await;
    Ok(ReviewsRefreshResponse {
        fetched_at: utc_now(),
        items: fetched.items,
        missing_pull_request_ids: fetched.missing,
    })
}

pub(super) async fn reconcile_targeted_missing_task_board_reviews(
    database: Option<&AsyncDaemonDb>,
    request: &ReviewsRefreshRequest,
    missing_pull_request_ids: &[String],
    expected_revision: u64,
) -> Result<bool, CliError> {
    let Some(database) = database else {
        return Ok(true);
    };
    let snapshots = missing_review_snapshots(&request.targets, missing_pull_request_ids);
    if snapshots.is_empty() {
        return Ok(true);
    }
    let Some(_revision_guard) = stable_data_revision_guard(expected_revision).await else {
        return Ok(false);
    };
    for item in database.list_task_board_items(None).await? {
        database
            .update_task_board_item(&item.id, |current| {
                Ok(reconcile_review_item_from_snapshots(current, &snapshots))
            })
            .await?;
    }
    Ok(GitHubProtectedClient::data_revision() == expected_revision)
}

fn missing_review_snapshots(
    targets: &[ReviewTarget],
    missing_pull_request_ids: &[String],
) -> Vec<GitHubPullRequestSnapshot> {
    let missing = missing_pull_request_ids
        .iter()
        .map(|id| id.trim())
        .collect::<HashSet<_>>();
    let unavailable_at = utc_now();
    targets
        .iter()
        .filter(|target| missing.contains(target.pull_request_id.trim()))
        .map(|target| GitHubPullRequestSnapshot {
            repository: target.repository.clone(),
            number: target.number,
            is_open: Some(false),
            viewer_review_requested: Some(false),
            updated_at: unavailable_at.clone(),
        })
        .collect()
}

struct ReviewsRefreshFetch {
    items: Vec<ReviewItem>,
    missing: Vec<String>,
    repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    authoritative_viewer_keys: HashSet<String>,
}

async fn fetch_reviews_refresh_once(
    request: &ReviewsRefreshRequest,
) -> Result<ReviewsRefreshFetch, CliError> {
    let mut items_by_key = BTreeMap::new();
    let mut missing = Vec::new();
    let mut repository_labels = BTreeMap::new();
    let mut authoritative_viewer_keys = HashSet::new();
    for segment in token_bound_targets(&request.targets)? {
        let ids = segment
            .targets
            .iter()
            .map(|target| target.pull_request_id.clone())
            .collect::<Vec<_>>();
        let client = ReviewsGitHubClient::new(&segment.token)?;
        let fetch = client.fetch_by_ids(&ids, request).await?;
        for item in fetch.items {
            let key = review_item_key(&item);
            // Both viewer-scoped values come directly from the authenticated node query.
            authoritative_viewer_keys.insert(key.clone());
            items_by_key.insert(key, item);
        }
        missing.extend(fetch.missing);
        merge_segment_repository_labels(&mut repository_labels, fetch.repository_labels);
    }
    Ok(ReviewsRefreshFetch {
        items: items_by_key.into_values().collect(),
        missing,
        repository_labels,
        authoritative_viewer_keys,
    })
}
