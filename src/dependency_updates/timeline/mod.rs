#![allow(dead_code)]

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdateTimelineEntry {
    pub id: String,
}
