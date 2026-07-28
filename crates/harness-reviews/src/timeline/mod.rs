#![allow(dead_code, unused_imports)]

mod cache;
mod client;
mod mapping;
mod queries;
mod service;
mod types;

pub use client::TimelineGitHubClient;

pub use service::{TimelineClient, TimelineError, fetch_timeline_page};

/// Clears the in-memory timeline cache and returns how many pages
/// were evicted. Called from the daemon's combined cache-clear
/// endpoint so a single DELETE drops body, query, and timeline state
/// in one shot.
#[must_use]
pub fn drain_timeline_cache() -> usize {
    cache::drain_all_counted()
}

#[must_use]
pub fn map_timeline_node(node: &serde_json::Value) -> Option<ReviewTimelineEntry> {
    mapping::map_node(node)
}

pub fn append_timeline_entry_to_cache(pull_request_id: &str, entry: &ReviewTimelineEntry) {
    cache::append_entry(pull_request_id, entry);
}

/// Drain the cached timeline pages for `pull_request_id`. Called by
/// the daemon service layer after a write action (comment-post,
/// review-thread resolve) succeeds so the next fetch reflects the new
/// server-side state without an extra GitHub round-trip.
pub fn drain_pull_request_cache(pull_request_id: &str) {
    cache::drain_pull_request(pull_request_id);
}

// Predates this crate's own clippy::pedantic gate; allow the pure style
// lints below rather than rewrite an otherwise-passing test.
#[cfg(test)]
#[allow(clippy::cognitive_complexity)]
mod tests;

#[cfg(test)]
#[allow(clippy::needless_pass_by_value, clippy::unnecessary_trailing_comma)]
mod service_tests;

pub use types::{
    Actor, CommitEntry, HeadRefForcePushedEntry, IssueCommentEntry, ReviewEntry,
    ReviewInlineCommentEntry, ReviewState, ReviewThreadCommentEntry, ReviewThreadEntry,
    ReviewTimelineEntry, SimpleActorEventEntry, SimpleActorEventKind, UnknownEntry,
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsTimelineRequest {
    pub pull_request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    pub page_size: u32,
    pub direction: TimelinePageDirection,
    #[serde(default)]
    pub force_refresh: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(value_type = Option<String>, format = DateTime)]
    pub pull_request_updated_at: Option<DateTime<Utc>>,
}

#[derive(
    Debug,
    Clone,
    Copy,
    PartialEq,
    Eq,
    Hash,
    PartialOrd,
    Ord,
    Serialize,
    Deserialize,
    utoipa::ToSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum TimelinePageDirection {
    Older,
    Newer,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsTimelineResponse {
    pub pull_request_id: String,
    pub entries: Vec<ReviewTimelineEntry>,
    pub page_info: TimelinePageInfo,
    pub viewer_can_comment: bool,
    #[schema(value_type = String, format = DateTime)]
    pub fetched_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TimelinePageInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_cursor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_cursor: Option<String>,
    pub has_older: bool,
    pub has_newer: bool,
}
