use super::*;

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

pub(crate) fn timeline_cursor_matches(entry: &TimelineEntry, cursor: &TimelineCursor) -> bool {
    entry.entry_id == cursor.entry_id && entry.recorded_at == cursor.recorded_at
}

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

pub(crate) fn reconcile_active_session_liveness_for_reads(
    _include_all: bool,
    db: Option<&super::db::DaemonDb>,
) -> Result<(), CliError> {
    let Some(db) = db else {
        return Ok(());
    };
    let session_ids: BTreeSet<_> = db
        .list_session_summaries()?
        .into_iter()
        .filter(|state| {
            state.status == SessionStatus::Active && state.metrics.active_agent_count > 0
        })
        .map(|state| state.session_id)
        .collect();
    let stale_session_ids = stale_session_ids_for_liveness_refresh_now(session_ids, Instant::now());
    for session_id in stale_session_ids {
        if let Err(error) = reconcile_session_liveness_for_read(&session_id, Some(db)) {
            clear_session_liveness_refresh_cache_entry(&session_id);
            return Err(error);
        }
    }
    Ok(())
}

pub(crate) fn stale_session_ids_for_liveness_refresh(
    cache: &mut BTreeMap<String, Instant>,
    session_ids: BTreeSet<String>,
    now: Instant,
) -> Vec<String> {
    cache.retain(|session_id, _| session_ids.contains(session_id));
    let mut stale_session_ids = Vec::new();
    for session_id in session_ids {
        let should_refresh = cache.get(&session_id).is_none_or(|last_refresh| {
            now.saturating_duration_since(*last_refresh) >= SESSION_LIVENESS_REFRESH_TTL
        });
        if should_refresh {
            cache.insert(session_id.clone(), now);
            stale_session_ids.push(session_id);
        }
    }
    stale_session_ids
}

pub(crate) fn stale_session_ids_for_liveness_refresh_now(
    session_ids: BTreeSet<String>,
    now: Instant,
) -> Vec<String> {
    let cache = SESSION_LIVENESS_REFRESH_CACHE.get_or_init(|| Mutex::new(BTreeMap::new()));
    match cache.lock() {
        Ok(mut cache) => stale_session_ids_for_liveness_refresh(&mut cache, session_ids, now),
        Err(_) => session_ids.into_iter().collect(),
    }
}

pub(crate) fn clear_session_liveness_refresh_cache_entry(session_id: &str) {
    let Some(cache) = SESSION_LIVENESS_REFRESH_CACHE.get() else {
        return;
    };
    let Ok(mut cache) = cache.lock() else {
        return;
    };
    cache.remove(session_id);
}

pub(crate) fn reconcile_session_liveness_for_read(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<(), CliError> {
    // Only reconcile when a daemon DB is available. Without a running daemon
    // there is no liveness data to compare against.
    let Some(db) = db else {
        return Ok(());
    };
    if let Some(project_dir) = liveness_project_dir(session_id, db)? {
        let result = session_service::sync_agent_liveness(session_id, &project_dir)?;
        if !result.disconnected.is_empty() || !result.idled.is_empty() {
            db.resync_session(session_id)?;
        }
    }
    Ok(())
}

pub(crate) fn liveness_project_dir(
    session_id: &str,
    db: &super::db::DaemonDb,
) -> Result<Option<PathBuf>, CliError> {
    let Some(resolved) = db.resolve_session(session_id)? else {
        return Ok(None);
    };
    if resolved.state.status != SessionStatus::Active {
        return Ok(None);
    }
    if !session_has_live_agents(&resolved.state) {
        return Ok(None);
    }
    let Some(project_dir) = resolved.project.project_dir else {
        return Ok(None);
    };
    if session_storage::load_state(&project_dir, session_id)?.is_none() {
        return Ok(None);
    }
    Ok(Some(project_dir))
}

pub(crate) fn session_has_live_agents(state: &SessionState) -> bool {
    state.agents.values().any(|agent| agent.status.is_alive())
}
