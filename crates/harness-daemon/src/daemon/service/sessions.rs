use super::{
    CliError, ProjectSummary, SessionDetail, SessionExtensionsPayload, SessionSummary,
    TimelineEntry, index, reconcile_expired_pending_signals_for_db, snapshot, timeline,
};
#[cfg(test)]
use super::{CliErrorKind, session_not_found};
#[cfg(test)]
use crate::daemon::db::timeline::DaemonDbTimeline;
use crate::daemon::db_timeline_source::DaemonDbTimelineHandle;
use crate::session::service::ResolvedRuntimeSessionAgent;
use harness_protocol::daemon::summaries::AcpTranscriptResponse;
#[cfg(test)]
use harness_protocol::timeline::TimelineCursor;
use harness_protocol::timeline::{TimelineWindowRequest, TimelineWindowResponse};

mod liveness;
mod snapshot_resolve;

pub(crate) use snapshot_resolve::{
    resolve_session_for_snapshot, resolve_session_for_snapshot_async,
};

use crate::daemon::db::prelude::*;
#[cfg(test)]
pub(crate) use liveness::clear_session_liveness_refresh_cache_entry;
#[cfg(test)]
pub(crate) use liveness::session_liveness_refresh_due_locked;
#[cfg(test)]
pub(crate) use liveness::stale_session_ids_for_liveness_refresh;
pub(crate) use liveness::{
    reconcile_active_session_liveness_background,
    reconcile_active_session_liveness_background_async,
};
use liveness::{reconcile_active_session_liveness_for_reads, reconcile_session_liveness_for_read};

/// List discovered projects known to the daemon.
///
/// # Errors
/// Returns [`CliError`] on project discovery failures.
pub fn list_projects(
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<Vec<ProjectSummary>, CliError> {
    harness_daemon_session_service::list_projects(db)
}

/// List discovered projects from the canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] on query failures.
pub(crate) async fn list_projects_async(
    async_db: Option<&crate::daemon::db_handle::AsyncDaemonDbHandle>,
) -> Result<Vec<ProjectSummary>, CliError> {
    harness_daemon_session_service::list_projects_async(async_db).await
}

/// List discovered sessions across all indexed projects.
///
/// # Errors
/// Returns [`CliError`] on session discovery failures.
pub fn list_sessions(
    include_all: bool,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<Vec<SessionSummary>, CliError> {
    reconcile_active_session_liveness_for_reads(include_all, db)?;
    if let Some(db) = db {
        return db.list_session_summaries_full();
    }
    snapshot::session_summaries(include_all)
}

/// List discovered sessions from the canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] on query failures.
pub(crate) async fn list_sessions_async(
    include_all: bool,
    async_db: Option<&crate::daemon::db_handle::AsyncDaemonDbHandle>,
) -> Result<Vec<SessionSummary>, CliError> {
    harness_daemon_session_service::list_sessions_async(include_all, async_db).await
}

/// Resolve a runtime-session ID to the orchestration session and agent
/// that own it, using a single indexed query against the canonical async DB.
///
/// # Errors
/// Returns [`CliError::session_ambiguous`] when more than one live agent
/// claims the same `(runtime, runtime_session_id)` pair, and propagates SQL
/// failures.
pub(crate) async fn resolve_runtime_session_agent_async(
    runtime_name: &str,
    runtime_session_id: &str,
    async_db: Option<&crate::daemon::db_handle::AsyncDaemonDbHandle>,
) -> Result<Option<ResolvedRuntimeSessionAgent>, CliError> {
    harness_daemon_session_service::resolve_runtime_session_agent_async(
        runtime_name,
        runtime_session_id,
        async_db,
    )
    .await
}

/// Load a single session detail snapshot.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub fn session_detail(
    session_id: &str,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    if harness_daemon_session_service::session_liveness_refresh_due_now(session_id) {
        reconcile_session_liveness_for_read(session_id, db)?;
    }
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return snapshot::session_detail_from_resolved_with_db(&resolved, db);
    }
    snapshot::session_detail(session_id)
}

/// Load a daemon-owned session detail snapshot without read-time reconciliation.
///
/// Mutation handlers use this to return the just-persisted canonical snapshot
/// without triggering additional liveness or signal side effects during the
/// response path.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub(crate) fn session_detail_from_daemon_db(
    session_id: &str,
    db: &crate::daemon::db_handle::DaemonDbOwnedHandle,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::session_detail_from_storage(session_id, db)
}

/// Load a full session detail snapshot from the canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub(crate) async fn session_detail_async(
    session_id: &str,
    async_db: Option<&crate::daemon::db_handle::AsyncDaemonDbHandle>,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::session_detail_async(session_id, async_db).await
}

/// Load a daemon-owned async session detail snapshot without read-time reconciliation.
///
/// Mutation handlers use this to return the just-persisted canonical snapshot
/// without triggering additional liveness or signal side effects during the
/// response path.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub(crate) async fn session_detail_from_async_daemon_db(
    session_id: &str,
    async_db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::session_detail_from_storage_async(session_id, async_db).await
}

/// Load a lightweight session detail with only in-memory fields from the
/// canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub(crate) async fn session_detail_core_async(
    session_id: &str,
    async_db: Option<&crate::daemon::db_handle::AsyncDaemonDbHandle>,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::session_detail_core_async(session_id, async_db).await
}

/// Load a session timeline window from the canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or the timeline
/// ledger cannot be loaded.
pub(crate) async fn session_timeline_window_async(
    session_id: &str,
    request: &TimelineWindowRequest,
    async_db: Option<&crate::daemon::db_handle::AsyncDaemonDbHandle>,
) -> Result<TimelineWindowResponse, CliError> {
    harness_daemon_session_service::session_timeline_window_async(session_id, request, async_db)
        .await
}

/// Load ACP transcript history for a session from the canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or transcript rows
/// cannot be loaded.
pub(crate) async fn session_acp_transcript_async(
    session_id: &str,
    async_db: Option<&crate::daemon::db_handle::AsyncDaemonDbHandle>,
) -> Result<AcpTranscriptResponse, CliError> {
    harness_daemon_session_service::session_acp_transcript_async(session_id, async_db).await
}

/// Load a merged session timeline.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or timeline sources fail.
pub fn session_timeline(
    session_id: &str,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<Vec<TimelineEntry>, CliError> {
    session_timeline_with_scope(session_id, timeline::TimelinePayloadScope::Full, db)
}

/// Load a merged session timeline with caller-selected payload detail.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or timeline sources fail.
pub(crate) fn session_timeline_with_scope(
    session_id: &str,
    payload_scope: timeline::TimelinePayloadScope,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<Vec<TimelineEntry>, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return timeline::session_timeline_from_resolved_with_db_scope(
            &resolved,
            &DaemonDbTimelineHandle(db),
            payload_scope,
        );
    }
    timeline::session_timeline_with_scope(session_id, payload_scope)
}

/// Load a session timeline window with metadata for incremental clients.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or timeline sources fail.
#[cfg(test)]
pub(crate) fn session_timeline_window(
    session_id: &str,
    request: &TimelineWindowRequest,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<TimelineWindowResponse, CliError> {
    if let Some(db) = db {
        db.resolve_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
    }
    if let Some(db) = db
        && let Some(response) = db.load_session_timeline_window(session_id, request)?
    {
        return Ok(response);
    }
    let payload_scope = match request.scope.as_deref() {
        Some("summary") => timeline::TimelinePayloadScope::Summary,
        _ => timeline::TimelinePayloadScope::Full,
    };
    let entries = session_timeline_with_scope(session_id, payload_scope, db)?;
    build_timeline_window_response(&entries, request)
}

#[cfg(test)]
pub(crate) fn build_timeline_window_response(
    entries: &[TimelineEntry],
    request: &TimelineWindowRequest,
) -> Result<TimelineWindowResponse, CliError> {
    let total_count = entries.len();
    let revision = i64::try_from(total_count).map_err(|error| {
        CliErrorKind::workflow_parse(format!("timeline revision overflow: {error}"))
    })?;
    let limit = request.limit.unwrap_or(total_count).max(1);

    if request.known_revision == Some(revision)
        && request.before.is_none()
        && request.after.is_none()
    {
        let latest_window_end = limit.min(total_count);
        return Ok(TimelineWindowResponse {
            revision,
            total_count,
            window_start: 0,
            window_end: latest_window_end,
            has_older: latest_window_end < total_count,
            has_newer: false,
            oldest_cursor: latest_window_end
                .checked_sub(1)
                .and_then(|index| entries.get(index))
                .map(cursor_from_entry),
            newest_cursor: entries.first().map(cursor_from_entry),
            entries: None,
            unchanged: true,
        });
    }

    let (window_start, window_entries) = if let Some(before) = &request.before {
        let start = entries
            .iter()
            .position(|entry| timeline_cursor_matches(entry, before))
            .map_or(total_count, |index| index + 1);
        let end = start.saturating_add(limit).min(total_count);
        (start, entries[start..end].to_vec())
    } else if let Some(after) = &request.after {
        let end = entries
            .iter()
            .position(|entry| timeline_cursor_matches(entry, after))
            .unwrap_or(0);
        let start = end.saturating_sub(limit);
        (start, entries[start..end].to_vec())
    } else {
        let end = limit.min(total_count);
        (0, entries[..end].to_vec())
    };

    let window_end = window_start + window_entries.len();

    Ok(TimelineWindowResponse {
        revision,
        total_count,
        window_start,
        window_end,
        has_older: window_end < total_count,
        has_newer: window_start > 0,
        oldest_cursor: window_entries.last().map(cursor_from_entry),
        newest_cursor: window_entries.first().map(cursor_from_entry),
        entries: Some(window_entries),
        unchanged: false,
    })
}

#[cfg(test)]
pub(crate) fn timeline_cursor_matches(entry: &TimelineEntry, cursor: &TimelineCursor) -> bool {
    entry.entry_id == cursor.entry_id && entry.recorded_at == cursor.recorded_at
}

#[cfg(test)]
pub(crate) fn cursor_from_entry(entry: &TimelineEntry) -> TimelineCursor {
    TimelineCursor {
        recorded_at: entry.recorded_at.clone(),
        entry_id: entry.entry_id.clone(),
    }
}

/// Load a lightweight session detail with only in-memory fields.
///
/// Returns agents and tasks from the resolved session state without any
/// database queries or filesystem I/O for signals, observer, or activity.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved.
pub fn session_detail_core(
    session_id: &str,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    if harness_daemon_session_service::session_liveness_refresh_due_now(session_id) {
        reconcile_session_liveness_for_read(session_id, db)?;
    }
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return Ok(snapshot::build_session_detail_core(&resolved));
    }
    let resolved = index::resolve_session(session_id)?;
    Ok(snapshot::build_session_detail_core(&resolved))
}

/// Load the expensive session detail extensions (signals, observer, activity).
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or extension loading fails.
pub fn session_extensions(
    session_id: &str,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<SessionExtensionsPayload, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return snapshot::build_session_extensions(&resolved, Some(db));
    }
    let resolved = index::resolve_session(session_id)?;
    snapshot::build_session_extensions(&resolved, None)
}

/// Load the expensive session detail extensions from the canonical async daemon DB.
///
/// This resolves the session from the async database, then loads the remaining
/// runtime-backed extension fields through the existing snapshot helpers.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or extension loading fails.
pub(crate) async fn session_extensions_async(
    session_id: &str,
    async_db: Option<&crate::daemon::db_handle::AsyncDaemonDbHandle>,
) -> Result<SessionExtensionsPayload, CliError> {
    harness_daemon_session_service::session_extensions_async(session_id, async_db).await
}
