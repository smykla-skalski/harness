use harness_daemon_snapshot as snapshot;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::summaries::AcpTranscriptResponse;
use harness_protocol::session_wire::ResolvedRuntimeSessionAgent;
use harness_protocol::timeline::{TimelineWindowRequest, TimelineWindowResponse};
use harness_session::index::ResolvedSession;
use harness_session::wire::{
    ProjectSummary, SessionDetail, SessionExtensionsPayload, SessionSummary,
};

use crate::liveness::{
    reconcile_active_session_liveness_for_reads_async, reconcile_session_liveness_for_read_async,
    session_liveness_refresh_due_now,
};
use crate::persistence::session_not_found;
use crate::ports::{AsyncSignalStorage, SignalStorage};
use crate::reconcile::reconcile_expired_pending_signals_async;

/// # Errors
/// Returns an error on project discovery failures.
pub fn list_projects<S: SignalStorage>(
    storage: Option<&S>,
) -> Result<Vec<ProjectSummary>, CliError> {
    if let Some(storage) = storage {
        return storage.list_project_summaries();
    }
    snapshot::project_summaries()
}

/// # Errors
/// Returns an error on query failures.
pub async fn list_projects_async<A: AsyncSignalStorage>(
    storage: Option<&A>,
) -> Result<Vec<ProjectSummary>, CliError> {
    let storage = storage.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async project reads",
        ))
    })?;
    storage.list_project_summaries().await
}

/// # Errors
/// Returns an error on query failures.
pub async fn list_sessions_async<A: AsyncSignalStorage>(
    include_all: bool,
    storage: Option<&A>,
) -> Result<Vec<SessionSummary>, CliError> {
    let storage = storage.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session reads",
        ))
    })?;
    reconcile_active_session_liveness_for_reads_async(include_all, Some(storage)).await?;
    storage.list_session_summaries().await
}

/// # Errors
/// Returns [`CliError::session_ambiguous`] when more than one live agent
/// claims the same `(runtime, runtime_session_id)` pair, and propagates SQL
/// failures.
pub async fn resolve_runtime_session_agent_async<A: AsyncSignalStorage>(
    runtime_name: &str,
    runtime_session_id: &str,
    storage: Option<&A>,
) -> Result<Option<ResolvedRuntimeSessionAgent>, CliError> {
    let storage = storage.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for runtime session resolution",
        ))
    })?;
    let mut matches = storage
        .resolve_runtime_session_agents(runtime_name, runtime_session_id)
        .await?;
    match matches.len() {
        0 => Ok(None),
        1 => {
            let (orchestration_session_id, agent_id) = matches.remove(0);
            Ok(Some(ResolvedRuntimeSessionAgent {
                orchestration_session_id,
                session_agent_id: agent_id,
            }))
        }
        _ => Err(CliErrorKind::session_ambiguous(format!(
            "runtime session '{runtime_session_id}' for runtime '{runtime_name}' \
             maps to multiple orchestration sessions"
        ))
        .into()),
    }
}

/// Load a daemon-owned session detail snapshot without read-time reconciliation.
///
/// # Errors
/// Returns an error when the session cannot be resolved or loaded.
pub fn session_detail_from_storage<S: SignalStorage + harness_daemon_snapshot::SnapshotStorage>(
    session_id: &str,
    storage: &S,
) -> Result<SessionDetail, CliError> {
    let resolved = storage
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    snapshot::session_detail_from_resolved_with_db(&resolved, storage)
}

async fn resolve_session_with_read_reconcile<'a, A: AsyncSignalStorage>(
    session_id: &str,
    storage: Option<&'a A>,
) -> Result<(&'a A, ResolvedSession), CliError> {
    let storage = storage.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session reads",
        ))
    })?;
    reconcile_expired_pending_signals_async(session_id, storage).await?;
    if session_liveness_refresh_due_now(session_id) {
        reconcile_session_liveness_for_read_async(session_id, Some(storage)).await?;
    }
    let resolved = storage
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    Ok((storage, resolved))
}

/// # Errors
/// Returns an error when the session cannot be resolved or loaded.
pub async fn session_detail_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: Option<&A>,
) -> Result<SessionDetail, CliError> {
    let (storage, resolved) = resolve_session_with_read_reconcile(session_id, storage).await?;
    let signals = storage.load_signals(session_id).await?;
    let agent_activity = storage.load_agent_activity(session_id).await?;
    snapshot::build_session_detail_from_cached_runtime_async(resolved, signals, agent_activity)
        .await
}

/// Load a daemon-owned async session detail snapshot without read-time reconciliation.
///
/// # Errors
/// Returns an error when the session cannot be resolved or loaded.
pub async fn session_detail_from_storage_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: &A,
) -> Result<SessionDetail, CliError> {
    let resolved = storage
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = storage.load_signals(session_id).await?;
    let agent_activity = storage.load_agent_activity(session_id).await?;
    snapshot::build_session_detail_from_cached_runtime_async(resolved, signals, agent_activity)
        .await
}

/// # Errors
/// Returns an error when the session cannot be resolved or loaded.
pub async fn session_detail_core_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: Option<&A>,
) -> Result<SessionDetail, CliError> {
    let (_, resolved) = resolve_session_with_read_reconcile(session_id, storage).await?;
    Ok(snapshot::build_session_detail_core(&resolved))
}

/// # Errors
/// Returns an error when the session cannot be resolved or the timeline
/// ledger cannot be loaded.
pub async fn session_timeline_window_async<A: AsyncSignalStorage>(
    session_id: &str,
    request: &TimelineWindowRequest,
    storage: Option<&A>,
) -> Result<TimelineWindowResponse, CliError> {
    let storage = storage.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session timeline reads",
        ))
    })?;
    storage
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    reconcile_expired_pending_signals_async(session_id, storage).await?;
    storage
        .load_session_timeline_window(session_id, request)
        .await?
        .ok_or_else(|| session_not_found(session_id))
}

/// # Errors
/// Returns an error when the session cannot be resolved or transcript rows
/// cannot be loaded.
pub async fn session_acp_transcript_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: Option<&A>,
) -> Result<AcpTranscriptResponse, CliError> {
    let storage = storage.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async ACP transcript reads",
        ))
    })?;
    storage
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    reconcile_expired_pending_signals_async(session_id, storage).await?;
    Ok(AcpTranscriptResponse {
        entries: storage
            .load_session_acp_transcript_entries(session_id)
            .await?,
    })
}

/// # Errors
/// Returns an error when the session cannot be resolved or extension loading fails.
pub async fn session_extensions_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: Option<&A>,
) -> Result<SessionExtensionsPayload, CliError> {
    let storage = storage.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "async daemon database pool is required for async session extension reads",
        ))
    })?;
    reconcile_expired_pending_signals_async(session_id, storage).await?;
    let resolved = storage
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = storage.load_signals(session_id).await?;
    let agent_activity = storage.load_agent_activity(session_id).await?;
    snapshot::build_session_extensions_from_cached_runtime_async(resolved, signals, agent_activity)
        .await
}
