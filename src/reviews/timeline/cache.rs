#![allow(dead_code)]

use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};

use super::{ReviewTimelineEntry, ReviewsTimelineResponse, TimelinePageDirection};

pub(super) const TIMELINE_CACHE_TTL: Duration = Duration::from_mins(5);

#[derive(Debug, Clone, PartialEq, Eq, Ord, PartialOrd)]
pub(super) struct TimelineCacheKey {
    pub pull_request_id: String,
    pub cursor: Option<String>,
    pub direction: TimelinePageDirection,
    pub pull_request_updated_at: Option<DateTime<Utc>>,
}

struct CachedTimelinePage {
    stored_at: Instant,
    response: ReviewsTimelineResponse,
}

static REVIEWS_TIMELINE_CACHE: OnceLock<Mutex<BTreeMap<TimelineCacheKey, CachedTimelinePage>>> =
    OnceLock::new();

fn cache() -> &'static Mutex<BTreeMap<TimelineCacheKey, CachedTimelinePage>> {
    REVIEWS_TIMELINE_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

/// Returns a cached page if its `stored_at + TTL` is still in the
/// future relative to `now`. The caller is the service handler in
/// A.9, which only invokes `store` after a successful full drain of
/// every nested comment connection — so a hit here always returns
/// fully-drained data.
pub(super) fn lookup(key: &TimelineCacheKey, now: Instant) -> Option<ReviewsTimelineResponse> {
    let map = cache().lock().expect("timeline cache lock poisoned");
    let entry = map.get(key)?;
    let age = now.saturating_duration_since(entry.stored_at);
    if age >= TIMELINE_CACHE_TTL {
        return None;
    }
    Some(entry.response.clone())
}

/// Stores a fully-drained timeline page. The drain-success contract is
/// the service handler's responsibility (see plan §2.6); the cache
/// layer does no verification.
pub(super) fn store(key: TimelineCacheKey, response: ReviewsTimelineResponse, now: Instant) {
    let mut map = cache().lock().expect("timeline cache lock poisoned");
    map.insert(
        key,
        CachedTimelinePage {
            stored_at: now,
            response,
        },
    );
}

/// Drops every cached page that belongs to the given pull request.
/// Force-refresh requests funnel through here; the service handler
/// also calls this after a self-initiated comment post so a follow-up
/// fetch from another PR detail pane re-pulls the new entry.
pub(super) fn drain_pull_request(pull_request_id: &str) {
    let mut map = cache().lock().expect("timeline cache lock poisoned");
    map.retain(|key, _| key.pull_request_id != pull_request_id);
}

/// Appends a newly-created entry to cached first pages for the PR. Cursor pages
/// stay untouched because a just-posted comment cannot belong to older pages.
pub(super) fn append_entry(pull_request_id: &str, entry: &ReviewTimelineEntry) {
    let now = Instant::now();
    let mut map = cache().lock().expect("timeline cache lock poisoned");
    for (key, cached) in &mut *map {
        if key.pull_request_id != pull_request_id
            || key.cursor.is_some()
            || key.direction != TimelinePageDirection::Older
        {
            continue;
        }
        if cached
            .response
            .entries
            .iter()
            .any(|existing| existing.id() == entry.id())
        {
            continue;
        }
        cached.response.entries.push(entry.clone());
        cached.response.fetched_at = Utc::now();
        cached.stored_at = now;
    }
}

/// Drops every cached page. Wired into the existing
/// `/v1/reviews/cache` DELETE endpoint in A.10 so a clean
/// session boundary drops timeline state as well.
pub(super) fn drain_all() {
    let mut map = cache().lock().expect("timeline cache lock poisoned");
    map.clear();
}

/// Same as [`drain_all`] but returns how many entries were evicted —
/// used by the daemon's cache-clear endpoint to roll the timeline
/// count into the existing `ReviewsCacheClearResponse`.
pub(super) fn drain_all_counted() -> usize {
    let mut map = cache().lock().expect("timeline cache lock poisoned");
    let count = map.len();
    map.clear();
    count
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    use crate::reviews::timeline::TimelinePageInfo;

    fn empty_response(pull_request_id: &str) -> ReviewsTimelineResponse {
        ReviewsTimelineResponse {
            pull_request_id: pull_request_id.to_string(),
            entries: Vec::new(),
            page_info: TimelinePageInfo {
                start_cursor: None,
                end_cursor: None,
                has_older: false,
                has_newer: false,
            },
            viewer_can_comment: true,
            fetched_at: Utc.with_ymd_and_hms(2026, 5, 22, 12, 0, 0).unwrap(),
        }
    }

    fn parse_updated_at(value: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(value)
            .expect("valid rfc3339 timestamp")
            .with_timezone(&Utc)
    }

    fn key_for(
        pr: &str,
        cursor: Option<&str>,
        pull_request_updated_at: Option<&str>,
    ) -> TimelineCacheKey {
        TimelineCacheKey {
            pull_request_id: pr.to_string(),
            cursor: cursor.map(str::to_string),
            direction: TimelinePageDirection::Older,
            pull_request_updated_at: pull_request_updated_at.map(parse_updated_at),
        }
    }

    #[test]
    fn cache_returns_fresh_within_ttl() {
        let pr = "cache-fresh-pr";
        drain_pull_request(pr);
        let t0 = Instant::now();
        store(key_for(pr, None, None), empty_response(pr), t0);
        let hit = lookup(&key_for(pr, None, None), t0 + Duration::from_secs(60));
        assert!(hit.is_some(), "fresh entry should resolve");
        assert_eq!(hit.unwrap().pull_request_id, pr);
        drain_pull_request(pr);
    }

    #[test]
    fn cache_returns_none_after_ttl() {
        let pr = "cache-expired-pr";
        drain_pull_request(pr);
        let t0 = Instant::now();
        store(key_for(pr, None, None), empty_response(pr), t0);
        let probe = t0 + TIMELINE_CACHE_TTL + Duration::from_secs(1);
        assert!(
            lookup(&key_for(pr, None, None), probe).is_none(),
            "expired entry must miss",
        );
        drain_pull_request(pr);
    }

    #[test]
    fn cache_force_refresh_drains_only_target_pr() {
        let pr_a = "cache-drain-a";
        let pr_b = "cache-drain-b";
        drain_pull_request(pr_a);
        drain_pull_request(pr_b);
        let t0 = Instant::now();
        store(key_for(pr_a, None, None), empty_response(pr_a), t0);
        store(key_for(pr_b, None, None), empty_response(pr_b), t0);
        drain_pull_request(pr_a);
        assert!(lookup(&key_for(pr_a, None, None), t0).is_none());
        assert!(lookup(&key_for(pr_b, None, None), t0).is_some());
        drain_pull_request(pr_b);
    }

    #[test]
    fn cache_distinct_cursors_do_not_collide() {
        let pr = "cache-cursor-pr";
        drain_pull_request(pr);
        let t0 = Instant::now();
        store(key_for(pr, None, None), empty_response(pr), t0);
        store(key_for(pr, Some("c2"), None), empty_response(pr), t0);
        assert!(lookup(&key_for(pr, None, None), t0).is_some());
        assert!(lookup(&key_for(pr, Some("c2"), None), t0).is_some());
        assert!(
            lookup(&key_for(pr, Some("missing"), None), t0).is_none(),
            "unrelated cursor must miss",
        );
        drain_pull_request(pr);
    }

    #[test]
    fn cache_distinct_revisions_do_not_collide() {
        let pr = "cache-revision-pr";
        drain_pull_request(pr);
        let t0 = Instant::now();
        store(key_for(pr, None, None), empty_response(pr), t0);
        store(
            key_for(pr, None, Some("2026-05-22T12:00:00Z")),
            empty_response(pr),
            t0,
        );
        assert!(lookup(&key_for(pr, None, None), t0).is_some());
        assert!(
            lookup(&key_for(pr, None, Some("2026-05-22T12:00:00Z")), t0).is_some()
        );
        assert!(
            lookup(&key_for(pr, None, Some("2026-05-23T12:00:00Z")), t0).is_none(),
            "a different pull-request revision must miss",
        );
        drain_pull_request(pr);
    }
}
