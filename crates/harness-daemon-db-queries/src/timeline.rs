//! Pure `StoredTimelineEntry` construction helpers, split out from
//! `harness-daemon`'s `db::timeline` trait file rather than moved wholesale:
//! `DaemonDbTimeline::rebuild_session_timeline_from_resolved` (and its
//! `backfill_*` callers) constructs `db_timeline_source::DaemonDbTimelineHandle`,
//! a `harness-daemon`-local orphan-rule wrapper that itself needs
//! `session_data::SessionCoreQueries` - still `harness-daemon`-local, not yet
//! extracted. That one method (and the trait it lives on) has to stay behind
//! until `session_data.rs` moves too; these functions have no such dependency
//! and move cleanly on their own.

use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::timeline::{TimelineCursor, TimelineEntry};

use crate::stored_timeline_entry::StoredTimelineEntry;

/// Row shape of a session's cached timeline-summary state
/// (`session_timeline_state`). Used only by `harness-daemon`'s own
/// `#[cfg(test)]` `DaemonDbTimeline` methods, which stayed behind (see this
/// module's own doc comment) - not `#[cfg(test)]` here, since that gate would
/// only activate for this crate's own test build, not a downstream crate's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionTimelineStateRow {
    pub session_id: String,
    pub revision: i64,
    pub entry_count: usize,
    pub newest_recorded_at: Option<String>,
    pub oldest_recorded_at: Option<String>,
    pub integrity_hash: String,
    pub updated_at: String,
}

/// # Errors
/// Returns [`CliError`] when the timeline payload cannot be serialized.
pub fn stored_timeline_entry(
    source_kind: &str,
    source_key: String,
    entry: &TimelineEntry,
) -> Result<StoredTimelineEntry, CliError> {
    Ok(StoredTimelineEntry {
        session_id: entry.session_id.clone(),
        entry_id: entry.entry_id.clone(),
        source_kind: source_kind.to_string(),
        source_key,
        recorded_at: entry.recorded_at.clone(),
        kind: entry.kind.clone(),
        agent_id: entry.agent_id.clone(),
        task_id: entry.task_id.clone(),
        summary: entry.summary.clone(),
        payload_json: serde_json::to_string(&entry.payload)
            .map_err(|error| db_error(format!("serialize timeline payload: {error}")))?,
        sort_recorded_at: entry.recorded_at.clone(),
        sort_tiebreaker: entry.entry_id.clone(),
    })
}

/// # Errors
/// Returns [`CliError`] when the timeline payload cannot be serialized.
pub fn stored_timeline_entry_for_rebuild(
    entry: &TimelineEntry,
) -> Result<StoredTimelineEntry, CliError> {
    let (source_kind, source_key) = timeline_source_identity(entry);
    stored_timeline_entry(source_kind, source_key, entry)
}

fn timeline_source_identity(entry: &TimelineEntry) -> (&'static str, String) {
    if let Some(sequence) = entry.entry_id.strip_prefix("log-") {
        return ("log", format!("log:{sequence}"));
    }
    if entry.kind == "task_checkpoint" {
        return ("checkpoint", format!("checkpoint:{}", entry.entry_id));
    }
    if let Some(signal_id) = entry.entry_id.strip_prefix("signal-ack-") {
        return ("signal_ack", format!("signal_ack:{signal_id}"));
    }
    if let Some(observe_id) = entry.entry_id.strip_prefix("observe-snapshot-") {
        return ("observe", format!("observe:{observe_id}"));
    }
    if matches!(
        entry.kind.as_str(),
        "tool_invocation"
            | "tool_result"
            | "tool_result_error"
            | "agent_error"
            | "signal_received"
            | "agent_state_change"
            | "file_modification"
            | "agent_session_marker"
    ) && let Some(agent_id) = entry.agent_id.as_deref()
        && let Some((_, sequence)) = entry.entry_id.rsplit_once('-')
    {
        return (
            "conversation",
            format!("conversation:{agent_id}:{sequence}"),
        );
    }
    ("derived", entry.entry_id.clone())
}

/// # Errors
/// Returns [`rusqlite::Error`] on column read failures.
pub fn stored_timeline_entry_from_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<StoredTimelineEntry> {
    Ok(StoredTimelineEntry {
        session_id: row.get(0)?,
        entry_id: row.get(1)?,
        source_kind: row.get(2)?,
        source_key: row.get(3)?,
        recorded_at: row.get(4)?,
        kind: row.get(5)?,
        agent_id: row.get(6)?,
        task_id: row.get(7)?,
        summary: row.get(8)?,
        payload_json: row.get(9)?,
        sort_recorded_at: row.get(10)?,
        sort_tiebreaker: row.get(11)?,
    })
}

#[must_use]
pub fn cursor_from_timeline_entry(entry: &TimelineEntry) -> TimelineCursor {
    TimelineCursor {
        recorded_at: entry.recorded_at.clone(),
        entry_id: entry.entry_id.clone(),
    }
}
