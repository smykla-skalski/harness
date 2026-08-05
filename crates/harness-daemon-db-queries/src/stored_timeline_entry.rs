use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::timeline::TimelineEntry;
use harness_timeline::TimelinePayloadScope;

/// Row-shaped intermediate between a `session_timeline_entries` read and the
/// wire-facing [`TimelineEntry`] - kept distinct from the wire type so a
/// summary-scope read can skip parsing `payload_json` entirely.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredTimelineEntry {
    pub session_id: String,
    pub entry_id: String,
    pub source_kind: String,
    pub source_key: String,
    pub recorded_at: String,
    pub kind: String,
    pub agent_id: Option<String>,
    pub task_id: Option<String>,
    pub summary: String,
    pub payload_json: String,
    pub sort_recorded_at: String,
    pub sort_tiebreaker: String,
}

impl StoredTimelineEntry {
    /// # Errors
    /// Returns [`CliError`] when `payload_json` is not valid JSON.
    pub fn into_timeline_entry(
        self,
        payload_scope: TimelinePayloadScope,
    ) -> Result<TimelineEntry, CliError> {
        let payload = if payload_scope == TimelinePayloadScope::Summary {
            serde_json::Value::Object(serde_json::Map::new())
        } else {
            serde_json::from_str(&self.payload_json).map_err(|error| {
                db_error(format!("parse timeline payload {}: {error}", self.entry_id))
            })?
        };
        Ok(TimelineEntry {
            entry_id: self.entry_id,
            recorded_at: self.recorded_at,
            kind: self.kind,
            session_id: self.session_id,
            agent_id: self.agent_id,
            task_id: self.task_id,
            summary: self.summary,
            payload,
        })
    }
}
