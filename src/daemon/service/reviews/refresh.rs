use std::collections::{BTreeMap, HashSet};

use crate::errors::CliError;
use crate::github_api::GitHubProtectedClient;
use crate::reviews::{
    ReviewItem, ReviewRepositoryLabel, ReviewsGitHubClient, ReviewsRefreshRequest,
    ReviewsRefreshResponse,
};
use crate::workspace::utc_now;

use super::cache_internal::{patch_cached_items, patch_cached_repository_labels};
use super::token::token_bound_targets;
use super::{
    github_projection, merge_segment_repository_labels, policy, policy_event_inbox, review_item_key,
};

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
    let fetched = loop {
        let (fetched, revision) = fetch_reviews_refresh_stably(request).await?;
        if github_projection::reconcile_task_board(
            &fetched.items,
            &fetched.authoritative_viewer_keys,
            github_projection::MissingReviewResolution::ProvidedSnapshotsOnly,
            request.backport_detection_enabled,
            &request.backport_patterns,
            revision,
        )
        .await
        {
            break fetched;
        }
    };
    if !fetched.repository_labels.is_empty() {
        patch_cached_repository_labels(&fetched.repository_labels);
    }
    patch_cached_items(&fetched.items, &fetched.missing);
    policy_event_inbox::resume_waiting_reviews_policy_runs(&fetched.items).await;
    policy::start_background_reviews_policy_runs(&fetched.items).await;
    Ok(ReviewsRefreshResponse {
        fetched_at: utc_now(),
        items: fetched.items,
        missing_pull_request_ids: fetched.missing,
    })
}

struct ReviewsRefreshFetch {
    items: Vec<ReviewItem>,
    missing: Vec<String>,
    repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    authoritative_viewer_keys: HashSet<String>,
}

async fn fetch_reviews_refresh_stably(
    request: &ReviewsRefreshRequest,
) -> Result<(ReviewsRefreshFetch, u64), CliError> {
    loop {
        let revision = GitHubProtectedClient::data_revision();
        let fetched = fetch_reviews_refresh_once(request).await?;
        if GitHubProtectedClient::data_revision() == revision {
            return Ok((fetched, revision));
        }
    }
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
        let viewer_login = client.fetch_viewer_login().await;
        let fetch = client
            .fetch_by_ids(&ids, request, viewer_login.as_deref())
            .await?;
        for item in fetch.items {
            let key = review_item_key(&item);
            if viewer_login.is_some() {
                authoritative_viewer_keys.insert(key.clone());
                items_by_key.insert(key, item);
            } else {
                items_by_key.entry(key).or_insert(item);
            }
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
