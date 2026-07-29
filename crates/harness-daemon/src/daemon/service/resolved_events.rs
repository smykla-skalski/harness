//! Stream-event builders that work from an already-resolved session.
//!
//! The post-mutation snapshot broadcaster resolves a session once and builds
//! every event from that single [`ResolvedSession`], rather than re-resolving
//! per event. These helpers keep that construction in one place.

use crate::daemon::index::ResolvedSession;
use crate::daemon::snapshot;

use super::observe_stream::stream_event;
use super::{
    CliError, SessionUpdatedPayload, SessionsUpdatedDeltaPayload, StreamEvent, list_projects,
    list_projects_async,
};

/// Build a core `session_updated` event from an already-resolved session.
pub(super) fn session_updated_core_event_from_resolved(
    resolved: &ResolvedSession,
) -> Result<StreamEvent, CliError> {
    let payload = SessionUpdatedPayload {
        detail: snapshot::build_session_detail_core(resolved),
        timeline: None,
        extensions_pending: true,
    };
    stream_event("session_updated", Some(&resolved.state.session_id), payload)
}

/// Build a `session_extensions` event from an already-resolved session using
/// the synchronous DB for the expensive extension fields.
pub(super) fn session_extensions_event_from_resolved(
    resolved: &ResolvedSession,
    db: &super::db::DaemonDb,
) -> Result<StreamEvent, CliError> {
    let payload = snapshot::build_session_extensions(resolved, Some(db))?;
    stream_event(
        "session_extensions",
        Some(&resolved.state.session_id),
        payload,
    )
}

/// Build a `session_extensions` event from an already-resolved session using
/// the canonical async DB for signals and agent activity.
pub(super) async fn session_extensions_event_from_resolved_async(
    resolved: &ResolvedSession,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<StreamEvent, CliError> {
    let session_id = resolved.state.session_id.as_str();
    let signals = async_db.load_signals(session_id).await?;
    let agent_activity = async_db.load_agent_activity(session_id).await?;
    let payload =
        snapshot::build_session_extensions_from_cached_runtime(resolved, signals, agent_activity)?;
    stream_event("session_extensions", Some(session_id), payload)
}

/// Build a `sessions_updated_delta` event carrying a single changed session.
pub(super) fn sessions_updated_delta_changed_event(
    resolved: &ResolvedSession,
    db: &super::db::DaemonDb,
) -> Result<StreamEvent, CliError> {
    let payload = SessionsUpdatedDeltaPayload {
        changed: vec![snapshot::summary_from_resolved(resolved)],
        removed: Vec::new(),
        projects: list_projects(Some(db))?,
    };
    stream_event(
        "sessions_updated_delta",
        Some(&resolved.state.session_id),
        payload,
    )
}

/// Build a `sessions_updated_delta` event marking a single session removed.
pub(super) fn sessions_updated_delta_removed_event(
    session_id: &str,
    db: &super::db::DaemonDb,
) -> Result<StreamEvent, CliError> {
    let payload = SessionsUpdatedDeltaPayload {
        changed: Vec::new(),
        removed: vec![session_id.to_string()],
        projects: list_projects(Some(db))?,
    };
    stream_event("sessions_updated_delta", Some(session_id), payload)
}

/// Async counterpart of [`sessions_updated_delta_changed_event`].
pub(super) async fn sessions_updated_delta_changed_event_async(
    resolved: &ResolvedSession,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<StreamEvent, CliError> {
    let payload = SessionsUpdatedDeltaPayload {
        changed: vec![snapshot::summary_from_resolved(resolved)],
        removed: Vec::new(),
        projects: list_projects_async(Some(async_db)).await?,
    };
    stream_event(
        "sessions_updated_delta",
        Some(&resolved.state.session_id),
        payload,
    )
}

/// Async counterpart of [`sessions_updated_delta_removed_event`].
pub(super) async fn sessions_updated_delta_removed_event_async(
    session_id: &str,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<StreamEvent, CliError> {
    let payload = SessionsUpdatedDeltaPayload {
        changed: Vec::new(),
        removed: vec![session_id.to_string()],
        projects: list_projects_async(Some(async_db)).await?,
    };
    stream_event("sessions_updated_delta", Some(session_id), payload)
}
