#![allow(dead_code, unused_imports)]

mod cache;
mod client;
mod mapping;
mod queries;
mod service;
mod types;

pub(crate) use client::TimelineGitHubClient;

pub(crate) use service::{TimelineClient, TimelineError, fetch_timeline_page};

/// Clears the in-memory timeline cache and returns how many pages
/// were evicted. Called from the daemon's combined cache-clear
/// endpoint so a single DELETE drops body, query, and timeline state
/// in one shot.
pub(crate) fn drain_timeline_cache() -> usize {
    cache::drain_all_counted()
}

pub(crate) fn map_timeline_node(node: &serde_json::Value) -> Option<ReviewTimelineEntry> {
    mapping::map_node(node)
}

pub(crate) fn append_timeline_entry_to_cache(
    pull_request_id: &str,
    entry: ReviewTimelineEntry,
) {
    cache::append_entry(pull_request_id, entry);
}

/// Drain the cached timeline pages for `pull_request_id`. Called by
/// the daemon service layer after a write action (comment-post,
/// review-thread resolve) succeeds so the next fetch reflects the new
/// server-side state without an extra GitHub round-trip.
pub(crate) fn drain_pull_request_cache(pull_request_id: &str) {
    cache::drain_pull_request(pull_request_id);
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod service_tests;

pub use types::{
    Actor, CommitEntry, ReviewTimelineEntry, HeadRefForcePushedEntry, IssueCommentEntry,
    ReviewEntry, ReviewInlineCommentEntry, ReviewState, ReviewThreadCommentEntry,
    ReviewThreadEntry, SimpleActorEventEntry, SimpleActorEventKind, UnknownEntry,
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsTimelineRequest {
    pub pull_request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    pub page_size: u32,
    pub direction: TimelinePageDirection,
    #[serde(default)]
    pub force_refresh: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimelinePageDirection {
    Older,
    Newer,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsTimelineResponse {
    pub pull_request_id: String,
    pub entries: Vec<ReviewTimelineEntry>,
    pub page_info: TimelinePageInfo,
    pub viewer_can_comment: bool,
    pub fetched_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimelinePageInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_cursor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_cursor: Option<String>,
    pub has_older: bool,
    pub has_newer: bool,
}
