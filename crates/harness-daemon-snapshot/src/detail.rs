use tokio::task::spawn_blocking;

use harness_kernel::errors::{CliError, CliErrorKind};
use harness_session::index::{self, ResolvedSession};
use harness_session::ordering::{sort_session_agents, sort_session_tasks};
use harness_session::types::{AgentRegistration, SessionSignalRecord, SessionState, WorkItem};
use harness_session::wire::{AgentToolActivitySummary, SessionDetail, SessionExtensionsPayload};

use crate::activity::load_agent_activity_for;
use crate::observer::load_observer_summary;
use crate::signals::load_signals_for_resolved;
use crate::storage::SnapshotStorage;
use crate::summaries::summary_from_resolved;

/// Build a rich session detail snapshot, then persist it into the daemon cache.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn session_detail(session_id: &str) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    session_detail_from_resolved(&resolved)
}

/// Build session detail from a pre-resolved session (avoids full discovery).
///
/// # Errors
/// Returns [`CliError`] on parse failures.
pub fn session_detail_from_resolved(resolved: &ResolvedSession) -> Result<SessionDetail, CliError> {
    build_session_detail(resolved, None)
}

/// Build session detail using the DB for signal reads when available.
///
/// # Errors
/// Returns [`CliError`] on parse failures.
pub fn session_detail_from_resolved_with_db(
    resolved: &ResolvedSession,
    db: &dyn SnapshotStorage,
) -> Result<SessionDetail, CliError> {
    build_session_detail(resolved, Some(db))
}

fn build_session_detail(
    resolved: &ResolvedSession,
    db: Option<&dyn SnapshotStorage>,
) -> Result<SessionDetail, CliError> {
    let mut agents = visible_session_agents(&resolved.state);
    sort_session_agents(&mut agents);

    let mut tasks = visible_session_tasks(&resolved.state);
    sort_session_tasks(&mut tasks);

    let signals = load_signals_for_resolved(resolved, db)?;
    let agent_activity = if let Some(db) = db {
        db.load_agent_activity(&resolved.state.session_id)?
    } else {
        load_agent_activity_for(&resolved.project, &resolved.state)?
    };

    Ok(SessionDetail {
        session: summary_from_resolved(resolved),
        agents,
        tasks,
        signals,
        observer: load_observer_summary(&resolved.project, &resolved.state)?,
        agent_activity,
    })
}

/// Build a lightweight session detail with only in-memory fields.
///
/// Agents and tasks are taken directly from the resolved session state
/// without any database queries or filesystem I/O. Signals, observer,
/// and agent activity are left empty for deferred loading.
#[must_use]
pub fn build_session_detail_core(resolved: &ResolvedSession) -> SessionDetail {
    let mut agents = visible_session_agents(&resolved.state);
    sort_session_agents(&mut agents);

    let mut tasks = visible_session_tasks(&resolved.state);
    sort_session_tasks(&mut tasks);

    SessionDetail {
        session: summary_from_resolved(resolved),
        agents,
        tasks,
        signals: vec![],
        observer: None,
        agent_activity: vec![],
    }
}

fn visible_session_agents(state: &SessionState) -> Vec<AgentRegistration> {
    state
        .agents
        .values()
        .filter(|agent| agent.status.is_alive())
        .cloned()
        .collect()
}

fn visible_session_tasks(state: &SessionState) -> Vec<WorkItem> {
    state
        .tasks
        .values()
        .filter(|task| !task.is_deleted())
        .cloned()
        .collect()
}

/// Build the expensive session detail extensions (signals, observer, activity).
///
/// # Errors
/// Returns [`CliError`] on filesystem or database read failures.
pub fn build_session_extensions(
    resolved: &ResolvedSession,
    db: Option<&dyn SnapshotStorage>,
) -> Result<SessionExtensionsPayload, CliError> {
    let signals = load_signals_for_resolved(resolved, db)?;
    let agent_activity = if let Some(db) = db {
        db.load_agent_activity(&resolved.state.session_id)?
    } else {
        load_agent_activity_for(&resolved.project, &resolved.state)?
    };
    build_session_extensions_from_cached_runtime(resolved, signals, agent_activity)
}

pub(crate) fn build_session_detail_from_cached_runtime(
    resolved: &ResolvedSession,
    signals: Vec<SessionSignalRecord>,
    agent_activity: Vec<AgentToolActivitySummary>,
) -> Result<SessionDetail, CliError> {
    let mut detail = build_session_detail_core(resolved);
    detail.signals = signals;
    detail.observer = load_observer_summary(&resolved.project, &resolved.state)?;
    detail.agent_activity = agent_activity;
    Ok(detail)
}

/// Build session extensions from already-resolved signals and activity.
///
/// # Errors
/// Returns [`CliError`] on filesystem read failures.
pub fn build_session_extensions_from_cached_runtime(
    resolved: &ResolvedSession,
    signals: Vec<SessionSignalRecord>,
    agent_activity: Vec<AgentToolActivitySummary>,
) -> Result<SessionExtensionsPayload, CliError> {
    Ok(SessionExtensionsPayload {
        session_id: resolved.state.session_id.clone(),
        signals: Some(signals),
        observer: load_observer_summary(&resolved.project, &resolved.state)?,
        agent_activity: Some(agent_activity),
    })
}

/// Build session detail off the async executor (observer summary is a blocking read).
///
/// # Errors
/// Returns [`CliError`] on filesystem read failures or worker join failure.
pub async fn build_session_detail_from_cached_runtime_async(
    resolved: ResolvedSession,
    signals: Vec<SessionSignalRecord>,
    agent_activity: Vec<AgentToolActivitySummary>,
) -> Result<SessionDetail, CliError> {
    spawn_blocking(move || {
        build_session_detail_from_cached_runtime(&resolved, signals, agent_activity)
    })
    .await
    .unwrap_or_else(|error| {
        Err(CliErrorKind::workflow_io(format!("session detail worker failed: {error}")).into())
    })
}

/// Build session extensions off the async executor (observer summary is a blocking read).
///
/// # Errors
/// Returns [`CliError`] on filesystem read failures or worker join failure.
pub async fn build_session_extensions_from_cached_runtime_async(
    resolved: ResolvedSession,
    signals: Vec<SessionSignalRecord>,
    agent_activity: Vec<AgentToolActivitySummary>,
) -> Result<SessionExtensionsPayload, CliError> {
    spawn_blocking(move || {
        build_session_extensions_from_cached_runtime(&resolved, signals, agent_activity)
    })
    .await
    .unwrap_or_else(|error| {
        Err(CliErrorKind::workflow_io(format!("session extensions worker failed: {error}")).into())
    })
}
