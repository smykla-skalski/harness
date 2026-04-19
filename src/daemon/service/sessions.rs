#[cfg(test)]
use super::TimelineCursor;
use super::{
    CliError, CliErrorKind, ProjectSummary, SessionDetail, SessionExtensionsPayload,
    SessionSummary, TimelineEntry, TimelineWindowRequest, TimelineWindowResponse, index,
    reconcile_expired_pending_signals_for_async_db, reconcile_expired_pending_signals_for_db,
    session_not_found, snapshot, timeline,
};

mod liveness;

#[cfg(test)]
pub(crate) use liveness::clear_session_liveness_refresh_cache_entry;
#[cfg(test)]
pub(crate) use liveness::stale_session_ids_for_liveness_refresh;
use liveness::{
    reconcile_active_session_liveness_for_reads, reconcile_active_session_liveness_for_reads_async,
    reconcile_session_liveness_for_read, reconcile_session_liveness_for_read_async,
};

/// List discovered projects known to the daemon.
///
/// # Errors
/// Returns [`CliError`] on project discovery failures.
pub fn list_projects(db: Option<&super::db::DaemonDb>) -> Result<Vec<ProjectSummary>, CliError> {
    if let Some(db) = db {
        return db.list_project_summaries();
    }
    snapshot::project_summaries()
}

/// List discovered projects from the canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] on query failures.
pub(crate) async fn list_projects_async(
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<Vec<ProjectSummary>, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async project reads",
        ))
    })?;
    async_db.list_project_summaries().await
}

/// List discovered sessions across all indexed projects.
///
/// # Errors
/// Returns [`CliError`] on session discovery failures.
pub fn list_sessions(
    include_all: bool,
    db: Option<&super::db::DaemonDb>,
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
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<Vec<SessionSummary>, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session reads",
        ))
    })?;
    reconcile_active_session_liveness_for_reads_async(include_all, Some(async_db)).await?;
    async_db.list_session_summaries().await
}

/// Resolve a runtime-session ID to the orchestration session and agent
/// that own it, using a single indexed query against the canonical async DB.
///
/// The indexed lookup replaces the previous fan-out over
/// `list_sessions` + `session_detail` that every hook invocation performed
/// to translate a runtime session ID into a signal delivery target.
///
/// # Errors
/// Returns [`CliError::session_ambiguous`] when more than one live agent
/// claims the same `(runtime, runtime_session_id)` pair, and propagates SQL
/// failures.
pub(crate) async fn resolve_runtime_session_agent_async(
    runtime_name: &str,
    runtime_session_id: &str,
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<Option<crate::session::service::ResolvedRuntimeSessionAgent>, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for runtime session resolution",
        ))
    })?;
    let mut matches = async_db
        .resolve_runtime_session_agents(runtime_name, runtime_session_id)
        .await?;
    match matches.len() {
        0 => Ok(None),
        1 => {
            let (orchestration_session_id, agent_id) = matches.remove(0);
            Ok(Some(
                crate::session::service::ResolvedRuntimeSessionAgent {
                    orchestration_session_id,
                    agent_id,
                },
            ))
        }
        _ => Err(CliErrorKind::session_ambiguous(format!(
            "runtime session '{runtime_session_id}' for runtime '{runtime_name}' \
             maps to multiple orchestration sessions"
        ))
        .into()),
    }
}

/// Load a single session detail snapshot.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub fn session_detail(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    reconcile_session_liveness_for_read(session_id, db)?;
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
    db: &super::db::DaemonDb,
) -> Result<SessionDetail, CliError> {
    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    snapshot::session_detail_from_resolved_with_db(&resolved, db)
}

/// Load a full session detail snapshot from the canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub(crate) async fn session_detail_async(
    session_id: &str,
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<SessionDetail, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session reads",
        ))
    })?;
    reconcile_expired_pending_signals_for_async_db(session_id, async_db).await?;
    reconcile_session_liveness_for_read_async(session_id, Some(async_db)).await?;
    let resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = async_db.load_signals(session_id).await?;
    let agent_activity = async_db.load_agent_activity(session_id).await?;
    snapshot::build_session_detail_from_cached_runtime(&resolved, signals, agent_activity)
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
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = async_db.load_signals(session_id).await?;
    let agent_activity = async_db.load_agent_activity(session_id).await?;
    snapshot::build_session_detail_from_cached_runtime(&resolved, signals, agent_activity)
}

/// Load a lightweight session detail with only in-memory fields from the
/// canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or loaded.
pub(crate) async fn session_detail_core_async(
    session_id: &str,
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<SessionDetail, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session reads",
        ))
    })?;
    reconcile_expired_pending_signals_for_async_db(session_id, async_db).await?;
    reconcile_session_liveness_for_read_async(session_id, Some(async_db)).await?;
    let resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    Ok(snapshot::build_session_detail_core(&resolved))
}

/// Load a session timeline window from the canonical async daemon DB.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or the timeline
/// ledger cannot be loaded.
pub(crate) async fn session_timeline_window_async(
    session_id: &str,
    request: &TimelineWindowRequest,
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<TimelineWindowResponse, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session timeline reads",
        ))
    })?;
    reconcile_expired_pending_signals_for_async_db(session_id, async_db).await?;
    async_db
        .load_session_timeline_window(session_id, request)
        .await?
        .ok_or_else(|| session_not_found(session_id))
}

/// Load a merged session timeline.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved or timeline sources fail.
pub fn session_timeline(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
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
    db: Option<&super::db::DaemonDb>,
) -> Result<Vec<TimelineEntry>, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return timeline::session_timeline_from_resolved_with_db_scope(
            &resolved,
            db,
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
    db: Option<&super::db::DaemonDb>,
) -> Result<TimelineWindowResponse, CliError> {
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
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db {
        reconcile_expired_pending_signals_for_db(session_id, db)?;
    }
    reconcile_session_liveness_for_read(session_id, db)?;
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
    db: Option<&super::db::DaemonDb>,
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
    async_db: Option<&super::db::AsyncDaemonDb>,
) -> Result<SessionExtensionsPayload, CliError> {
    let async_db = async_db.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session extension reads",
        ))
    })?;
    reconcile_expired_pending_signals_for_async_db(session_id, async_db).await?;
    let resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = async_db.load_signals(session_id).await?;
    let agent_activity = async_db.load_agent_activity(session_id).await?;
    snapshot::build_session_extensions_from_cached_runtime(&resolved, signals, agent_activity)
}
