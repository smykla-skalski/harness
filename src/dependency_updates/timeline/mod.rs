#![allow(dead_code, unused_imports)]

mod cache;
mod client;
mod mapping;
mod queries;
mod service;
mod types;

pub(crate) use client::TimelineGitHubClient;

pub(crate) use service::{fetch_timeline_page, TimelineClient, TimelineError};

/// Clears the in-memory timeline cache and returns how many pages
/// were evicted. Called from the daemon's combined cache-clear
/// endpoint so a single DELETE drops body, query, and timeline state
/// in one shot.
pub(crate) fn drain_timeline_cache() -> usize {
    cache::drain_all_counted()
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod service_tests;

pub use types::{
    Actor, CommitEntry, DependencyUpdateTimelineEntry, HeadRefForcePushedEntry, IssueCommentEntry,
    ReviewEntry, ReviewInlineCommentEntry, ReviewState, ReviewThreadCommentEntry,
    ReviewThreadEntry, SimpleActorEventEntry, SimpleActorEventKind, UnknownEntry,
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesTimelineRequest {
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
pub struct DependencyUpdatesTimelineResponse {
    pub pull_request_id: String,
    pub entries: Vec<DependencyUpdateTimelineEntry>,
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

