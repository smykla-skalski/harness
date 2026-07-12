use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use crate::github_api::GitHubProtectedClient;
use crate::reviews::{
    ReviewItem, ReviewPullRequestState, ReviewRepositoryLabel, ReviewsBodyResponse,
    ReviewsQueryResponse, ReviewsSummary,
};

static REVIEWS_CACHE: OnceLock<Mutex<BTreeMap<String, CachedReviews>>> = OnceLock::new();
static REVIEWS_BODY_CACHE: OnceLock<Mutex<BTreeMap<String, CachedReviewBody>>> = OnceLock::new();

#[derive(Clone)]
pub(crate) struct CachedReviews {
    stored_at: Instant,
    github_data_revision: u64,
    response: ReviewsQueryResponse,
    authoritative_viewer_keys: HashSet<String>,
}

#[derive(Clone)]
pub(crate) struct CachedReviewBody {
    stored_at: Instant,
    github_data_revision: u64,
    response: ReviewsBodyResponse,
}

pub(crate) fn cache() -> &'static Mutex<BTreeMap<String, CachedReviews>> {
    REVIEWS_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn body_cache() -> &'static Mutex<BTreeMap<String, CachedReviewBody>> {
    REVIEWS_BODY_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

#[cfg(test)]
pub(crate) fn cached_query_response(
    cache_key: &str,
    max_age_seconds: u64,
) -> Option<ReviewsQueryResponse> {
    cached_query_source_at_revision(
        cache_key,
        max_age_seconds,
        GitHubProtectedClient::data_revision(),
    )
    .map(|(response, _)| response)
}

pub(super) fn cached_query_source_at_revision(
    cache_key: &str,
    max_age_seconds: u64,
    github_data_revision: u64,
) -> Option<(ReviewsQueryResponse, HashSet<String>)> {
    let cache = cache().lock().expect("reviews cache lock");
    let entry = cache.get(cache_key)?;
    if entry.github_data_revision != github_data_revision {
        return None;
    }
    if entry.stored_at.elapsed().as_secs() > max_age_seconds {
        return None;
    }
    let mut response = entry.response.clone();
    response.from_cache = true;
    Some((response, entry.authoritative_viewer_keys.clone()))
}

#[cfg(test)]
pub(crate) fn store_cached_query_response(cache_key: String, response: &ReviewsQueryResponse) {
    let authoritative_viewer_keys = response
        .items
        .iter()
        .filter(|item| item.flags.viewer_is_requested_reviewer)
        .map(|item| format!("{}#{}", item.repository.to_ascii_lowercase(), item.number))
        .collect();
    store_cached_query_response_at_revision(
        cache_key,
        response,
        &authoritative_viewer_keys,
        GitHubProtectedClient::data_revision(),
    );
}

pub(super) fn store_cached_query_response_at_revision(
    cache_key: String,
    response: &ReviewsQueryResponse,
    authoritative_viewer_keys: &HashSet<String>,
    github_data_revision: u64,
) {
    let mut cache = cache().lock().expect("reviews cache lock");
    cache.insert(
        cache_key,
        CachedReviews {
            stored_at: Instant::now(),
            github_data_revision,
            response: response.clone(),
            authoritative_viewer_keys: authoritative_viewer_keys.clone(),
        },
    );
}

pub(crate) fn cached_body_response(
    cache_key: &str,
    max_age_seconds: u64,
) -> Option<ReviewsBodyResponse> {
    cached_body_response_at_revision(
        cache_key,
        max_age_seconds,
        GitHubProtectedClient::data_revision(),
    )
}

fn cached_body_response_at_revision(
    cache_key: &str,
    max_age_seconds: u64,
    github_data_revision: u64,
) -> Option<ReviewsBodyResponse> {
    let cache = body_cache().lock().expect("reviews body cache lock");
    let entry = cache.get(cache_key)?;
    if entry.github_data_revision != github_data_revision {
        return None;
    }
    if entry.stored_at.elapsed().as_secs() > max_age_seconds {
        return None;
    }
    let mut response = entry.response.clone();
    response.from_cache = true;
    Some(response)
}

pub(crate) fn store_cached_body_response(cache_key: String, response: &ReviewsBodyResponse) {
    store_cached_body_response_at_revision(
        cache_key,
        response,
        GitHubProtectedClient::data_revision(),
    );
}

pub(super) fn store_cached_body_response_at_revision(
    cache_key: String,
    response: &ReviewsBodyResponse,
    github_data_revision: u64,
) {
    let mut cache = body_cache().lock().expect("reviews body cache lock");
    cache.insert(
        cache_key,
        CachedReviewBody {
            stored_at: Instant::now(),
            github_data_revision,
            response: response.clone(),
        },
    );
}

pub(crate) fn patch_cached_items(
    refreshed: &[ReviewItem],
    missing: &[String],
    authoritative_viewer_keys: &HashSet<String>,
) {
    if refreshed.is_empty() && missing.is_empty() {
        return;
    }
    let mut cache = cache().lock().expect("reviews cache lock");
    for entry in cache.values_mut() {
        patch_cached_authoritative_keys(entry, refreshed, missing, authoritative_viewer_keys);
        if let Some(updated) = apply_refresh_to_items(&entry.response.items, refreshed, missing) {
            entry.response.summary = ReviewsSummary::from_items(&updated);
            entry.response.items = updated;
        }
    }
}

fn patch_cached_authoritative_keys(
    entry: &mut CachedReviews,
    refreshed: &[ReviewItem],
    missing: &[String],
    authoritative_viewer_keys: &HashSet<String>,
) {
    for cached in &entry.response.items {
        if missing.contains(&cached.pull_request_id) {
            entry
                .authoritative_viewer_keys
                .remove(&review_item_key(cached));
        }
    }
    for item in refreshed {
        if !entry
            .response
            .items
            .iter()
            .any(|cached| cached.pull_request_id == item.pull_request_id)
        {
            continue;
        }
        let key = review_item_key(item);
        if authoritative_viewer_keys.contains(&key) {
            entry.authoritative_viewer_keys.insert(key);
        } else {
            entry.authoritative_viewer_keys.remove(&key);
        }
    }
}

fn review_item_key(item: &ReviewItem) -> String {
    format!("{}#{}", item.repository.to_ascii_lowercase(), item.number)
}

pub(crate) fn patch_cached_repository_labels(
    refreshed: &BTreeMap<String, Vec<ReviewRepositoryLabel>>,
) {
    let mut cache = cache().lock().expect("reviews cache lock");
    for entry in cache.values_mut() {
        for (repository, labels) in refreshed {
            if labels.is_empty() {
                continue;
            }
            entry
                .response
                .repository_labels
                .insert(repository.clone(), labels.clone());
        }
    }
}

/// Apply a targeted refresh result to a cached item list.
///
/// Returns `Some(new_items)` when the list changed (item replaced, missing
/// dropped, or no-longer-open item dropped) and `None` when the refresh did
/// not affect this list.
pub(crate) fn apply_refresh_to_items(
    items: &[ReviewItem],
    refreshed: &[ReviewItem],
    missing: &[String],
) -> Option<Vec<ReviewItem>> {
    let refreshed_by_id: HashMap<&str, &ReviewItem> = refreshed
        .iter()
        .map(|item| (item.pull_request_id.as_str(), item))
        .collect();
    let missing_ids: HashSet<&str> = missing.iter().map(String::as_str).collect();
    let mut next = Vec::with_capacity(items.len());
    let mut changed = false;

    for item in items {
        if missing_ids.contains(item.pull_request_id.as_str()) {
            changed = true;
            continue;
        }
        if let Some(refreshed_item) = refreshed_by_id.get(item.pull_request_id.as_str()) {
            changed = true;
            if refreshed_item.state == ReviewPullRequestState::Open {
                next.push((*refreshed_item).clone());
            }
            continue;
        }
        next.push(item.clone());
    }

    if changed { Some(next) } else { None }
}

#[cfg(test)]
mod revision_tests {
    use chrono::Utc;

    use super::*;

    #[test]
    fn query_cache_rejects_entries_from_an_older_github_revision() {
        let key = "reviews-cache-revision-query".to_string();
        let response = ReviewsQueryResponse::new(Vec::new(), "2026-07-11T12:00:00Z".into());
        store_cached_query_response_at_revision(key.clone(), &response, &HashSet::new(), 41);

        assert!(cached_query_source_at_revision(&key, 600, 42).is_none());
        assert!(cached_query_source_at_revision(&key, 600, 41).is_some());
    }

    #[test]
    fn body_cache_rejects_entries_from_an_older_github_revision() {
        let key = "reviews-cache-revision-body".to_string();
        let response = ReviewsBodyResponse {
            pull_request_id: "PR_revision_body".into(),
            body: "body before mutation".into(),
            pr_updated_at: Utc::now(),
            fetched_at: "2026-07-11T12:00:00Z".into(),
            from_cache: false,
        };
        store_cached_body_response_at_revision(key.clone(), &response, 17);

        assert!(cached_body_response_at_revision(&key, 600, 18).is_none());
        assert!(cached_body_response_at_revision(&key, 600, 17).is_some());
    }
}
