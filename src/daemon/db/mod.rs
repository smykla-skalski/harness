//! Canonical daemon persistence.
//!
//! Durable domain state belongs in `DaemonDb`. Files remain outside the
//! database only when a runtime or OS integration explicitly requires them,
//! such as manifests, auth tokens, lock files, and live signal/transcript
//! artifacts.

pub(crate) use std::borrow::Cow;
pub(crate) use std::collections::BTreeMap;
pub(crate) use std::fmt;
pub(crate) use std::io::{Error as IoError, ErrorKind};
pub(crate) use std::path::{Path, PathBuf};
pub(crate) use std::sync::{Arc, Mutex, OnceLock};

pub(crate) use rusqlite::{Connection, OptionalExtension, types::Type};
pub(crate) use sha2::{Digest, Sha256};

pub(crate) use crate::agents::runtime::event::ConversationEvent;
pub(crate) use crate::agents::runtime::signal::Signal;
pub(crate) use crate::daemon::agent_tui::{
    AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};
pub(crate) use crate::daemon::index::DiscoveredProject;
pub(crate) use crate::daemon::protocol::{
    CodexRunMode, CodexRunSnapshot, CodexRunStatus, TimelineCursor, TimelineEntry,
    TimelineWindowRequest, TimelineWindowResponse,
};
pub(crate) use crate::errors::{CliError, CliErrorKind};
pub(crate) use crate::session::types::{
    AgentRegistration, SessionLogEntry, SessionSignalRecord, SessionSignalStatus, SessionState,
    SessionStatus, TaskCheckpoint, WorkItem,
};
pub(crate) use crate::workspace::{project_context_dir, project_context_id, utc_now};

pub(crate) use super::{
    index as daemon_index, launchd as daemon_launchd, protocol as daemon_protocol,
    snapshot as daemon_snapshot, state, state as daemon_state, timeline as daemon_timeline,
};

mod async_agents;
mod async_bootstrap;
mod async_change_tracking;
mod async_conversation;
mod async_detail;
mod async_diagnostics;
mod async_pool;
mod async_reads;
mod async_runtime;
mod async_signal_writes;
mod async_writes;
mod conversation;
mod diagnostics;
mod imports;
mod rebuild;
mod runtime;
mod schema;
mod schema_repairs;
mod schema_sql;
mod schema_v10;
mod session_data;
mod signals;
mod summaries;
mod telemetry;
mod timeline;
mod timeline_store;
mod writes;

pub(crate) use async_pool::AsyncDaemonDb;
#[allow(unused_imports)]
use conversation::{
    clear_session_conversation_events, prepare_agent_conversation_imports_and_activity,
    prepare_runtime_transcript_resync_for_agents,
};
#[allow(unused_imports)]
use diagnostics::import_daemon_events;
pub(crate) use runtime::ensure_shared_db;
#[cfg(test)]
pub(crate) use schema::set_schema_init_hook;
pub(crate) use signals::ExpiredPendingSignalIndexRecord;
#[allow(unused_imports)]
use signals::derive_effective_signal_status;
pub(crate) use telemetry::{trace_async_db_operation, trace_sync_db_operation};
#[allow(unused_imports)]
use timeline::{stored_timeline_entry, stored_timeline_entry_from_row};
#[allow(unused_imports)]
use timeline_store::{
    replace_all_session_timeline_entries, replace_session_timeline_entries_for_prefix,
    upsert_session_timeline_entry,
};

pub(crate) fn normalize_change_scope(scope: &str) -> Cow<'_, str> {
    if scope == "global" || scope.starts_with("session:") {
        Cow::Borrowed(scope)
    } else {
        Cow::Owned(format!("session:{scope}"))
    }
}

pub(crate) fn session_id_from_change_scope(scope: &str) -> Option<&str> {
    if scope == "global" {
        None
    } else {
        Some(scope.strip_prefix("session:").unwrap_or(scope))
            .filter(|session_id| !session_id.is_empty())
    }
}

pub(crate) fn session_status_db_label(status: SessionStatus) -> Result<String, CliError> {
    let value = serde_json::to_value(status)
        .map_err(|error| db_error(format!("serialize session status: {error}")))?;
    value
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| db_error("serialize session status: expected string"))
}

#[must_use]
#[allow(dead_code)]
pub(crate) fn parse_session_status_db_label(status: &str) -> SessionStatus {
    serde_json::from_value(serde_json::Value::String(status.to_string()))
        .unwrap_or(SessionStatus::Ended)
}

/// `SQLite`-backed canonical storage for durable harness daemon state.
///
/// Operational files remain only for integration boundaries that cannot move
/// into the database.
pub struct DaemonDb {
    conn: Connection,
    path: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentTuiLiveRefreshState {
    pub(crate) status: AgentTuiStatus,
    pub(crate) updated_at: String,
}

#[derive(Debug)]
pub(crate) struct PreparedSessionResync {
    pub(crate) resolved: daemon_index::ResolvedSession,
    log_entries: Vec<SessionLogEntry>,
    task_checkpoints: Vec<PreparedTaskCheckpointImport>,
    signals: Vec<SessionSignalRecord>,
    activities: Vec<daemon_protocol::AgentToolActivitySummary>,
    conversation_events: Vec<PreparedConversationEventImport>,
}

#[derive(Debug)]
pub(crate) struct PreparedTaskCheckpointImport {
    checkpoints: Vec<TaskCheckpoint>,
}

#[derive(Debug)]
pub(crate) struct PreparedConversationEventImport {
    agent_id: String,
    runtime: String,
    events: Vec<ConversationEvent>,
}

#[derive(Debug)]
pub(crate) struct PreparedAgentTranscriptResync {
    agent_id: String,
    runtime: String,
    activity: daemon_protocol::AgentToolActivitySummary,
    events: Vec<ConversationEvent>,
}

#[derive(Debug)]
pub(crate) struct PreparedRuntimeTranscriptResync {
    session_id: String,
    agents: Vec<PreparedAgentTranscriptResync>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StoredTimelineEntry {
    session_id: String,
    entry_id: String,
    source_kind: String,
    source_key: String,
    recorded_at: String,
    kind: String,
    agent_id: Option<String>,
    task_id: Option<String>,
    summary: String,
    payload_json: String,
    sort_recorded_at: String,
    sort_tiebreaker: String,
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SessionTimelineStateRow {
    session_id: String,
    revision: i64,
    entry_count: usize,
    newest_recorded_at: Option<String>,
    oldest_recorded_at: Option<String>,
    integrity_hash: String,
    updated_at: String,
}

impl StoredTimelineEntry {
    fn into_timeline_entry(
        self,
        payload_scope: daemon_timeline::TimelinePayloadScope,
    ) -> Result<TimelineEntry, CliError> {
        let payload = if payload_scope == daemon_timeline::TimelinePayloadScope::Summary {
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

impl fmt::Debug for DaemonDb {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DaemonDb").finish_non_exhaustive()
    }
}

pub(crate) const SCHEMA_VERSION: &str = "10";

/// Summary of what was imported from file-based storage.
#[derive(Debug, Default)]
pub struct ImportResult {
    pub projects: usize,
    pub sessions: usize,
}

/// Summary of background file reconciliation.
#[derive(Debug, Default)]
pub struct ReconcileResult {
    pub projects: usize,
    pub sessions_imported: usize,
    pub sessions_skipped: usize,
}

/// Extract the serde tag from a serialized `SessionTransition` JSON string.
/// Returns the variant name (e.g. `SessionStarted`, `AgentJoined`) for indexing.
pub(crate) fn extract_transition_kind(json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| {
            value
                .as_object()
                .and_then(|object| object.keys().next().cloned())
                .or_else(|| value.as_str().map(String::from))
        })
        .unwrap_or_default()
}

pub(crate) fn db_error(detail: impl Into<Cow<'static, str>>) -> CliError {
    CliError::from(CliErrorKind::workflow_io(detail))
}

pub(crate) fn canonical_db_unavailable(operation: &str) -> CliError {
    CliError::from(CliErrorKind::workflow_io(format!(
        "daemon canonical database unavailable for {operation}"
    )))
}

#[expect(
    clippy::cast_possible_wrap,
    reason = "intentional bit-pattern reinterpretation for SQLite storage"
)]
pub(crate) const fn i64_from_u64(value: u64) -> i64 {
    value as i64
}

#[expect(
    clippy::cast_sign_loss,
    reason = "intentional bit-pattern reinterpretation for SQLite storage"
)]
pub(crate) const fn u64_from_i64(value: i64) -> u64 {
    value as u64
}

pub(crate) fn usize_from_i64(value: i64) -> usize {
    usize::try_from(value).unwrap_or(0)
}

#[cfg(test)]
mod tests;
