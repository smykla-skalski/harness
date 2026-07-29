use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One entry on a session's observation timeline.
///
/// Lives here rather than beside the daemon summaries it is served with,
/// because the managed-agent run contracts in this crate carry it and a leaf
/// crate cannot reach back into the daemon for a type.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TimelineEntry {
    pub entry_id: String,
    pub recorded_at: String,
    pub kind: String,
    pub session_id: String,
    pub agent_id: Option<String>,
    pub task_id: Option<String>,
    pub summary: String,
    pub payload: Value,
}

// Timeline pagination cursor and its window request/response, kept beside
// `TimelineEntry` for the same reason: `db` nests all four in its own read
// contracts and cannot depend back on the daemon crate for them.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, utoipa::ToSchema)]
pub struct TimelineCursor {
    pub recorded_at: String,
    pub entry_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct TimelineWindowRequest {
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub before: Option<TimelineCursor>,
    #[serde(default)]
    pub after: Option<TimelineCursor>,
    #[serde(default)]
    pub known_revision: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TimelineWindowResponse {
    pub revision: i64,
    pub total_count: usize,
    pub window_start: usize,
    pub window_end: usize,
    pub has_older: bool,
    pub has_newer: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oldest_cursor: Option<TimelineCursor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub newest_cursor: Option<TimelineCursor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entries: Option<Vec<TimelineEntry>>,
    pub unchanged: bool,
}
