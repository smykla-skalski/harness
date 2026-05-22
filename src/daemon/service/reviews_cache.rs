use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use crate::reviews::{
    ReviewItem, ReviewPullRequestState, ReviewRepositoryLabel,
    ReviewsBodyResponse, ReviewsQueryResponse, ReviewsSummary,
};

static REVIEWS_CACHE: OnceLock<Mutex<BTreeMap<String, CachedReviews>>> =
    OnceLock::new();
static REVIEWS_BODY_CACHE: OnceLock<
    Mutex<BTreeMap<String, CachedReviewBody>>,
> = OnceLock::new();

#[derive(Clone)]
pub(crate) struct CachedReviews {
    stored_at: Instant,
    response: ReviewsQueryResponse,
}

#[derive(Clone)]
pub(crate) struct CachedReviewBody {
    stored_at: Instant,
    response: ReviewsBodyResponse,
}

pub(crate) fn cache() -> &'static Mutex<BTreeMap<String, CachedReviews>> {
    REVIEWS_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn body_cache() -> &'static Mutex<BTreeMap<String, CachedReviewBody>> {
    REVIEWS_BODY_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn cached_query_response(
    cache_key: &str,
    max_age_seconds: u64,
) -> Option<ReviewsQueryResponse> {
    let cache = cache().lock().expect("reviews cache lock");
    let entry = cache.get(cache_key)?;
    if entry.stored_at.elapsed().as_secs() > max_age_seconds {
        return None;
    }
    let mut response = entry.response.clone();
    response.from_cache = true;
    Some(response)
}

pub(crate) fn store_cached_query_response(
    cache_key: String,
    response: &ReviewsQueryResponse,
) {
    let mut cache = cache().lock().expect("reviews cache lock");
    cache.insert(
        cache_key,
        CachedReviews {
            stored_at: Instant::now(),
            response: response.clone(),
        },
    );
}

pub(crate) fn cached_body_response(
    cache_key: &str,
    max_age_seconds: u64,
) -> Option<ReviewsBodyResponse> {
    let cache = body_cache()
        .lock()
        .expect("reviews body cache lock");
    let entry = cache.get(cache_key)?;
    if entry.stored_at.elapsed().as_secs() > max_age_seconds {
        return None;
    }
    let mut response = entry.response.clone();
    response.from_cache = true;
    Some(response)
}

pub(crate) fn store_cached_body_response(
    cache_key: String,
    response: &ReviewsBodyResponse,
) {
    let mut cache = body_cache()
        .lock()
        .expect("reviews body cache lock");
    cache.insert(
        cache_key,
        CachedReviewBody {
            stored_at: Instant::now(),
            response: response.clone(),
        },
    );
}

pub(crate) fn patch_cached_items(refreshed: &[ReviewItem], missing: &[String]) {
    if refreshed.is_empty() && missing.is_empty() {
        return;
    }
    let mut cache = cache().lock().expect("reviews cache lock");
    for entry in cache.values_mut() {
        if let Some(updated) = apply_refresh_to_items(&entry.response.items, refreshed, missing) {
            entry.response.summary = ReviewsSummary::from_items(&updated);
            entry.response.items = updated;
        }
    }
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
    let mut next = items.to_vec();
    let mut changed = false;
    for refreshed_item in refreshed {
        if let Some(slot) = next
            .iter_mut()
            .find(|item| item.pull_request_id == refreshed_item.pull_request_id)
        {
            *slot = refreshed_item.clone();
            changed = true;
        }
    }
    let pre_drop_len = next.len();
    next.retain(|item| {
        let dropped_by_missing = missing.contains(&item.pull_request_id);
        let dropped_by_state = refreshed
            .iter()
            .any(|refreshed_item| refreshed_item.pull_request_id == item.pull_request_id)
            && item.state != ReviewPullRequestState::Open;
        !(dropped_by_missing || dropped_by_state)
    });
    if next.len() != pre_drop_len {
        changed = true;
    }
    if changed { Some(next) } else { None }
}
