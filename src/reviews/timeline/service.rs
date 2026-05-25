#![allow(dead_code)]

use std::time::Instant;

use async_trait::async_trait;
use chrono::Utc;
use serde_json::Value;
use thiserror::Error;

use super::cache::{self, TimelineCacheKey};
use super::mapping;
use super::types::ReviewTimelineEntry;
use super::{ReviewsTimelineRequest, ReviewsTimelineResponse, TimelinePageInfo};

/// Maximum continuation calls per nested comment connection before
/// the service truncates and flags the entry as such. Set so the
/// pathological-input ceiling is roughly 10 × first-page size.
const CONTINUATION_DRAIN_BUDGET: u32 = 10;

#[derive(Debug, Error)]
pub enum TimelineError {
    #[error("upstream client error: {0}")]
    Client(String),
    #[error("rate limited")]
    RateLimited,
    #[error("graphql response missing required field: {0}")]
    Mapping(String),
}

/// GraphQL transport surface used by the service handler. The real
/// daemon GitHub client implements this in A.10; tests below ship a
/// queue-driven mock so the drain logic can be exercised offline.
#[async_trait]
pub(crate) trait TimelineClient: Send + Sync {
    async fn fetch_timeline_page_query(
        &self,
        pull_request_id: &str,
        page_size: u32,
        cursor: Option<&str>,
        inline_comment_page_size: u32,
        thread_comment_page_size: u32,
    ) -> Result<Value, TimelineError>;

    async fn list_review_comments(
        &self,
        review_id: &str,
        page_size: u32,
        cursor: Option<&str>,
    ) -> Result<Value, TimelineError>;

    async fn list_review_thread_comments(
        &self,
        thread_id: &str,
        page_size: u32,
        cursor: Option<&str>,
    ) -> Result<Value, TimelineError>;
}

const INITIAL_INLINE_COMMENT_PAGE_SIZE: u32 = 50;
const INITIAL_THREAD_COMMENT_PAGE_SIZE: u32 = 50;
const CONTINUATION_PAGE_SIZE: u32 = 100;

pub(crate) async fn fetch_timeline_page<C: TimelineClient>(
    request: ReviewsTimelineRequest,
    client: &C,
    now: Instant,
) -> Result<ReviewsTimelineResponse, TimelineError> {
    let key = TimelineCacheKey {
        pull_request_id: request.pull_request_id.clone(),
        cursor: request.cursor.clone(),
        direction: request.direction,
    };
    if request.force_refresh {
        cache::drain_pull_request(&request.pull_request_id);
    } else if let Some(cached) = cache::lookup(&key, now) {
        return Ok(cached);
    }

    let outer = client
        .fetch_timeline_page_query(
            &request.pull_request_id,
            request.page_size,
            request.cursor.as_deref(),
            INITIAL_INLINE_COMMENT_PAGE_SIZE,
            INITIAL_THREAD_COMMENT_PAGE_SIZE,
        )
        .await?;

    // The protected GraphQL client unwraps the outer `{data: ...}` envelope
    // before handing the value back, so the production payload looks like
    // `{node: ..., rateLimit: ...}`. Tests' MockClient mirrors that shape
    // verbatim; fixtures under `fixtures/*.json` keep the raw GitHub envelope
    // for parser-level mapping tests, but the service layer never sees it.
    let pr_node = outer
        .pointer("/node")
        .ok_or_else(|| TimelineError::Mapping("node missing".into()))?;
    let viewer_can_comment = mapping::viewer_can_comment_from_pull_request(pr_node);
    let timeline_items = pr_node
        .pointer("/timelineItems")
        .ok_or_else(|| TimelineError::Mapping("timelineItems missing".into()))?;
    let page_info_value = timeline_items.get("pageInfo");
    let start_cursor = page_info_value
        .and_then(|p| p.get("startCursor"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let end_cursor = page_info_value
        .and_then(|p| p.get("endCursor"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let has_older = page_info_value
        .and_then(|p| p.get("hasPreviousPage"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let has_newer = page_info_value
        .and_then(|p| p.get("hasNextPage"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let nodes = timeline_items
        .get("nodes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let entries = map_timeline_nodes(&nodes, client).await?;

    let response = ReviewsTimelineResponse {
        pull_request_id: request.pull_request_id.clone(),
        entries,
        page_info: TimelinePageInfo {
            start_cursor,
            end_cursor,
            has_older,
            has_newer,
        },
        viewer_can_comment,
        fetched_at: Utc::now(),
    };

    cache::store(key, response.clone(), now);
    Ok(response)
}

async fn map_timeline_nodes<C: TimelineClient>(
    nodes: &[Value],
    client: &C,
) -> Result<Vec<ReviewTimelineEntry>, TimelineError> {
    let mut entries: Vec<ReviewTimelineEntry> = Vec::with_capacity(nodes.len());
    for node in nodes {
        let typename = node
            .get("__typename")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match typename {
            "PullRequestReview" => {
                let (drained, truncated) = drain_review_comments(node, client).await?;
                let Some(entry) = mapping::map_node(&drained) else {
                    continue;
                };
                push_with_review_truncation(&mut entries, entry, truncated);
            }
            "PullRequestReviewThread" => {
                let (drained, truncated) = drain_review_thread_comments(node, client).await?;
                let Some(entry) = mapping::map_node(&drained) else {
                    continue;
                };
                push_with_thread_truncation(&mut entries, entry, truncated);
            }
            _ => {
                if let Some(entry) = mapping::map_node(node) {
                    entries.push(entry);
                }
            }
        }
    }
    Ok(entries)
}

fn push_with_review_truncation(
    entries: &mut Vec<ReviewTimelineEntry>,
    mut entry: ReviewTimelineEntry,
    truncated: bool,
) {
    if truncated {
        if let ReviewTimelineEntry::Review(ref mut r) = entry {
            r.comments_truncated = true;
        }
    }
    entries.push(entry);
}

fn push_with_thread_truncation(
    entries: &mut Vec<ReviewTimelineEntry>,
    mut entry: ReviewTimelineEntry,
    truncated: bool,
) {
    if truncated {
        if let ReviewTimelineEntry::ReviewThread(ref mut t) = entry {
            t.comments_truncated = true;
        }
    }
    entries.push(entry);
}

async fn drain_review_comments<C: TimelineClient>(
    review_node: &Value,
    client: &C,
) -> Result<(Value, bool), TimelineError> {
    let review_id = review_node
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| TimelineError::Mapping("review.id missing".into()))?
        .to_string();
    let comments = review_node.get("comments");
    let mut comments_array: Vec<Value> = comments
        .and_then(|c| c.get("nodes"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let page_info = comments.and_then(|c| c.get("pageInfo"));
    let mut cursor = page_info
        .and_then(|p| p.get("endCursor"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let mut has_next = page_info
        .and_then(|p| p.get("hasNextPage"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut calls = 0u32;
    let mut truncated = false;
    while has_next {
        if calls >= CONTINUATION_DRAIN_BUDGET {
            truncated = true;
            break;
        }
        let resp = client
            .list_review_comments(&review_id, CONTINUATION_PAGE_SIZE, cursor.as_deref())
            .await?;
        let nested = resp
            .pointer("/node/comments")
            .ok_or_else(|| TimelineError::Mapping("continuation comments missing".into()))?;
        if let Some(nodes) = nested.get("nodes").and_then(Value::as_array) {
            comments_array.extend(nodes.iter().cloned());
        }
        let next_page = nested.get("pageInfo");
        has_next = next_page
            .and_then(|p| p.get("hasNextPage"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        cursor = next_page
            .and_then(|p| p.get("endCursor"))
            .and_then(Value::as_str)
            .map(str::to_string);
        calls += 1;
    }
    let mut reconstructed = review_node.clone();
    if let Some(obj) = reconstructed
        .get_mut("comments")
        .and_then(Value::as_object_mut)
    {
        obj.insert("nodes".into(), Value::Array(comments_array));
        if let Some(pi) = obj.get_mut("pageInfo").and_then(Value::as_object_mut) {
            pi.insert("hasNextPage".into(), Value::Bool(false));
        }
    }
    Ok((reconstructed, truncated))
}

async fn drain_review_thread_comments<C: TimelineClient>(
    thread_node: &Value,
    client: &C,
) -> Result<(Value, bool), TimelineError> {
    let thread_id = thread_node
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| TimelineError::Mapping("review thread.id missing".into()))?
        .to_string();
    let comments = thread_node.get("comments");
    let mut comments_array: Vec<Value> = comments
        .and_then(|c| c.get("nodes"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let page_info = comments.and_then(|c| c.get("pageInfo"));
    let mut cursor = page_info
        .and_then(|p| p.get("endCursor"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let mut has_next = page_info
        .and_then(|p| p.get("hasNextPage"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut calls = 0u32;
    let mut truncated = false;
    while has_next {
        if calls >= CONTINUATION_DRAIN_BUDGET {
            truncated = true;
            break;
        }
        let resp = client
            .list_review_thread_comments(&thread_id, CONTINUATION_PAGE_SIZE, cursor.as_deref())
            .await?;
        let nested = resp
            .pointer("/node/comments")
            .ok_or_else(|| TimelineError::Mapping("continuation thread comments missing".into()))?;
        if let Some(nodes) = nested.get("nodes").and_then(Value::as_array) {
            comments_array.extend(nodes.iter().cloned());
        }
        let next_page = nested.get("pageInfo");
        has_next = next_page
            .and_then(|p| p.get("hasNextPage"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        cursor = next_page
            .and_then(|p| p.get("endCursor"))
            .and_then(Value::as_str)
            .map(str::to_string);
        calls += 1;
    }
    let mut reconstructed = thread_node.clone();
    if let Some(obj) = reconstructed
        .get_mut("comments")
        .and_then(Value::as_object_mut)
    {
        obj.insert("nodes".into(), Value::Array(comments_array));
        if let Some(pi) = obj.get_mut("pageInfo").and_then(Value::as_object_mut) {
            pi.insert("hasNextPage".into(), Value::Bool(false));
        }
    }
    Ok((reconstructed, truncated))
}
