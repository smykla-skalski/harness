use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One entry on a session's observation timeline.
///
/// Lives here rather than beside the daemon summaries it is served with,
/// because the managed-agent run contracts in this crate carry it and a leaf
/// crate cannot reach back into the daemon for a type.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
