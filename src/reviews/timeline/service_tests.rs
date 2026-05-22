#![cfg(test)]
#![allow(clippy::too_many_lines)]

use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use serde_json::{Value, json};

use super::cache;
use super::service::{TimelineClient, TimelineError, fetch_timeline_page};
use super::types::ReviewTimelineEntry;
use super::{ReviewsTimelineRequest, TimelinePageDirection};

struct MockClient {
    outer: Mutex<VecDeque<Result<Value, TimelineError>>>,
    inline: Mutex<VecDeque<Result<Value, TimelineError>>>,
    thread: Mutex<VecDeque<Result<Value, TimelineError>>>,
    outer_calls: AtomicUsize,
    inline_calls: AtomicUsize,
    thread_calls: AtomicUsize,
}

impl MockClient {
    fn new() -> Self {
        Self {
            outer: Mutex::new(VecDeque::new()),
            inline: Mutex::new(VecDeque::new()),
            thread: Mutex::new(VecDeque::new()),
            outer_calls: AtomicUsize::new(0),
            inline_calls: AtomicUsize::new(0),
            thread_calls: AtomicUsize::new(0),
        }
    }
    fn enqueue_outer(&self, r: Result<Value, TimelineError>) {
        self.outer.lock().unwrap().push_back(r);
    }
    fn enqueue_inline(&self, r: Result<Value, TimelineError>) {
        self.inline.lock().unwrap().push_back(r);
    }
    fn enqueue_thread(&self, r: Result<Value, TimelineError>) {
        self.thread.lock().unwrap().push_back(r);
    }
    fn outer_calls(&self) -> usize {
        self.outer_calls.load(Ordering::SeqCst)
    }
    fn inline_calls(&self) -> usize {
        self.inline_calls.load(Ordering::SeqCst)
    }
    fn thread_calls(&self) -> usize {
        self.thread_calls.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl TimelineClient for MockClient {
    async fn fetch_timeline_page_query(
        &self,
        _pull_request_id: &str,
        _page_size: u32,
        _cursor: Option<&str>,
        _inline_comment_page_size: u32,
        _thread_comment_page_size: u32,
    ) -> Result<Value, TimelineError> {
        self.outer_calls.fetch_add(1, Ordering::SeqCst);
        self.outer
            .lock()
            .unwrap()
            .pop_front()
            .expect("outer response queued")
    }
    async fn list_review_comments(
        &self,
        _review_id: &str,
        _page_size: u32,
        _cursor: Option<&str>,
    ) -> Result<Value, TimelineError> {
        self.inline_calls.fetch_add(1, Ordering::SeqCst);
        self.inline
            .lock()
            .unwrap()
            .pop_front()
            .expect("inline response queued")
    }
    async fn list_review_thread_comments(
        &self,
        _thread_id: &str,
        _page_size: u32,
        _cursor: Option<&str>,
    ) -> Result<Value, TimelineError> {
        self.thread_calls.fetch_add(1, Ordering::SeqCst);
        self.thread
            .lock()
            .unwrap()
            .pop_front()
            .expect("thread response queued")
    }
}

// Octocrab's `.graphql()` unwraps the outer `{data: ...}` envelope before
// the response reaches the service handler, so the mock returns the inner
// payload directly. Keep this aligned with `TimelineGitHubClient` in
// `client.rs`; the fixture files under `fixtures/*.json` keep the raw
// `{data: ...}` envelope because they exercise the lower-level mapping
// layer instead.
fn outer_page(pull_request_id: &str, nodes: Vec<Value>) -> Value {
    json!({
        "node": {
            "id": pull_request_id,
            "viewerCanUpdate": true,
            "timelineItems": {
                "pageInfo": {
                    "startCursor": "start",
                    "endCursor": "end",
                    "hasNextPage": false,
                    "hasPreviousPage": false,
                },
                "nodes": nodes,
            },
        },
        "rateLimit": { "remaining": 4990, "resetAt": "2026-05-22T15:00:00Z", "cost": 1 },
    })
}

fn review_node(review_id: &str, inline_nodes: Vec<Value>, has_next: bool) -> Value {
    json!({
        "__typename": "PullRequestReview",
        "id": review_id,
        "createdAt": "2026-05-22T11:00:00Z",
        "state": "COMMENTED",
        "body": null,
        "url": "https://github.com/example/repo/pull/1#pullrequestreview-99",
        "author": { "login": "alice", "avatarUrl": null },
        "comments": {
            "pageInfo": { "endCursor": "ic1", "hasNextPage": has_next },
            "nodes": inline_nodes,
        },
    })
}

fn inline_comment(id: &str, body: &str) -> Value {
    json!({
        "id": id,
        "path": "src/foo.rs",
        "position": 1,
        "body": body,
        "createdAt": "2026-05-22T11:01:00Z",
        "url": null,
        "replyTo": null,
        "author": { "login": "alice", "avatarUrl": null },
    })
}

fn inline_continuation(nodes: Vec<Value>, has_next: bool) -> Value {
    json!({
        "node": {
            "comments": {
                "pageInfo": { "endCursor": "ic-next", "hasNextPage": has_next },
                "nodes": nodes,
            }
        },
        "rateLimit": { "remaining": 4980, "resetAt": "2026-05-22T15:00:00Z", "cost": 1 },
    })
}

fn thread_node(thread_id: &str, comments: Vec<Value>, has_next: bool) -> Value {
    json!({
        "__typename": "PullRequestReviewThread",
        "id": thread_id,
        "isResolved": false,
        "isCollapsed": false,
        "path": "src/bar.rs",
        "line": 12,
        "originalLine": 12,
        "diffSide": "RIGHT",
        "comments": {
            "pageInfo": { "endCursor": "tc1", "hasNextPage": has_next },
            "nodes": comments,
        },
    })
}

fn thread_comment(id: &str, body: &str) -> Value {
    json!({
        "id": id,
        "body": body,
        "createdAt": "2026-05-22T11:05:00Z",
        "url": null,
        "author": { "login": "bob", "avatarUrl": null },
    })
}

fn thread_continuation(nodes: Vec<Value>, has_next: bool) -> Value {
    json!({
        "node": {
            "comments": {
                "pageInfo": { "endCursor": "tc-next", "hasNextPage": has_next },
                "nodes": nodes,
            }
        },
        "rateLimit": { "remaining": 4970, "resetAt": "2026-05-22T15:00:00Z", "cost": 1 },
    })
}

fn request_for(pr: &str) -> ReviewsTimelineRequest {
    ReviewsTimelineRequest {
        pull_request_id: pr.to_string(),
        cursor: None,
        page_size: 50,
        direction: TimelinePageDirection::Older,
        force_refresh: false,
    }
}

#[tokio::test]
async fn cache_miss_fetches_and_caches() {
    let pr = "service-cache-miss";
    cache::drain_pull_request(pr);
    let client = MockClient::new();
    client.enqueue_outer(Ok(outer_page(pr, vec![])));
    let resp = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect("fetch ok");
    assert_eq!(resp.pull_request_id, pr);
    assert!(resp.viewer_can_comment);
    assert_eq!(client.outer_calls(), 1);

    // second call: cache hit, no further outer fetch
    let _ = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect("cached ok");
    assert_eq!(client.outer_calls(), 1, "second call should hit cache");
    cache::drain_pull_request(pr);
}

#[tokio::test]
async fn force_refresh_drains_and_refetches() {
    let pr = "service-force-refresh";
    cache::drain_pull_request(pr);
    let client = MockClient::new();
    client.enqueue_outer(Ok(outer_page(pr, vec![])));
    client.enqueue_outer(Ok(outer_page(pr, vec![])));

    let _ = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect("first ok");
    assert_eq!(client.outer_calls(), 1);

    let mut force = request_for(pr);
    force.force_refresh = true;
    let _ = fetch_timeline_page(force, &client, Instant::now())
        .await
        .expect("forced ok");
    assert_eq!(client.outer_calls(), 2);
    cache::drain_pull_request(pr);
}

#[tokio::test]
async fn review_with_paginated_inline_comments_is_fully_drained() {
    let pr = "service-drain-review";
    cache::drain_pull_request(pr);
    let client = MockClient::new();
    let review = review_node(
        "PRR_drain",
        vec![
            inline_comment("c1", "first"),
            inline_comment("c2", "second"),
        ],
        true,
    );
    client.enqueue_outer(Ok(outer_page(pr, vec![review])));
    client.enqueue_inline(Ok(inline_continuation(
        vec![
            inline_comment("c3", "third"),
            inline_comment("c4", "fourth"),
        ],
        false,
    )));

    let resp = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect("drain ok");
    assert_eq!(client.inline_calls(), 1, "one continuation call");
    assert_eq!(resp.entries.len(), 1);
    let ReviewTimelineEntry::Review(r) = &resp.entries[0] else {
        panic!("expected Review");
    };
    assert_eq!(r.inline_comments.len(), 4, "all comments drained");
    assert_eq!(r.inline_comments[3].body, "fourth");
    assert!(!r.comments_truncated);
    cache::drain_pull_request(pr);
}

#[tokio::test]
async fn review_thread_with_paginated_comments_is_fully_drained() {
    let pr = "service-drain-thread";
    cache::drain_pull_request(pr);
    let client = MockClient::new();
    let thread = thread_node("PRRT_drain", vec![thread_comment("t1", "first")], true);
    client.enqueue_outer(Ok(outer_page(pr, vec![thread])));
    client.enqueue_thread(Ok(thread_continuation(
        vec![
            thread_comment("t2", "second"),
            thread_comment("t3", "third"),
        ],
        false,
    )));

    let resp = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect("drain ok");
    assert_eq!(client.thread_calls(), 1);
    let ReviewTimelineEntry::ReviewThread(t) = &resp.entries[0] else {
        panic!("expected ReviewThread");
    };
    assert_eq!(t.comments.len(), 3, "all thread comments drained");
    assert!(!t.comments_truncated);
    cache::drain_pull_request(pr);
}

#[tokio::test]
async fn continuation_fetch_failure_fails_whole_outer_page() {
    let pr = "service-drain-fail";
    cache::drain_pull_request(pr);
    let client = MockClient::new();
    let review = review_node("PRR_fail", vec![inline_comment("c1", "first")], true);
    client.enqueue_outer(Ok(outer_page(pr, vec![review])));
    client.enqueue_inline(Err(TimelineError::Client("transient".into())));

    let err = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect_err("should propagate continuation failure");
    assert!(matches!(err, TimelineError::Client(_)));

    // cache should be empty for this PR
    let key = super::cache::TimelineCacheKey {
        pull_request_id: pr.to_string(),
        cursor: None,
        direction: TimelinePageDirection::Older,
    };
    assert!(
        cache::lookup(&key, Instant::now()).is_none(),
        "no partial state cached after continuation failure",
    );
    cache::drain_pull_request(pr);
}

#[tokio::test]
async fn continuation_drain_respects_budget_and_flags_truncation() {
    let pr = "service-drain-budget";
    cache::drain_pull_request(pr);
    let client = MockClient::new();
    let review = review_node("PRR_budget", vec![inline_comment("c0", "head")], true);
    client.enqueue_outer(Ok(outer_page(pr, vec![review])));
    // 11 continuation pages all reporting hasNextPage=true; budget = 10
    for i in 0..11 {
        client.enqueue_inline(Ok(inline_continuation(
            vec![inline_comment(&format!("c{i}-extra"), "x")],
            true,
        )));
    }

    let resp = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect("budget ok");
    assert_eq!(client.inline_calls(), 10, "drain stops at the budget cap",);
    let ReviewTimelineEntry::Review(r) = &resp.entries[0] else {
        panic!("expected Review");
    };
    assert!(
        r.comments_truncated,
        "budget overflow surfaces as truncated"
    );
    // first-page (1) + 10 continuation pages * 1 comment each = 11
    assert_eq!(r.inline_comments.len(), 11);
    cache::drain_pull_request(pr);
}

#[tokio::test]
async fn cache_only_stores_fully_drained_pages() {
    let pr = "service-cache-drained-only";
    cache::drain_pull_request(pr);
    let client = MockClient::new();
    let review = review_node("PRR_cache_drain", vec![inline_comment("c1", "first")], true);
    client.enqueue_outer(Ok(outer_page(pr, vec![review.clone()])));
    client.enqueue_inline(Err(TimelineError::Client("boom".into())));
    let _ = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect_err("first attempt fails");

    // retry succeeds; the failed attempt left no partial cache
    client.enqueue_outer(Ok(outer_page(pr, vec![review])));
    client.enqueue_inline(Ok(inline_continuation(
        vec![inline_comment("c2", "second")],
        false,
    )));
    let resp = fetch_timeline_page(request_for(pr), &client, Instant::now())
        .await
        .expect("retry ok");
    let ReviewTimelineEntry::Review(r) = &resp.entries[0] else {
        panic!("expected Review");
    };
    assert_eq!(r.inline_comments.len(), 2);
    assert_eq!(
        client.outer_calls(),
        2,
        "second outer fetch needed after failure"
    );
    cache::drain_pull_request(pr);
}
