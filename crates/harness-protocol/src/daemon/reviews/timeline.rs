//! Timeline wire types relocated from `harness-reviews::timeline`. The
//! GraphQL fetch, caching, and node-mapping logic stay in `harness-reviews`;
//! only the request/response/page DTOs and the entry-kind enum tree move.

pub mod types;

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
