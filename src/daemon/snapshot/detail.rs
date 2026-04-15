use super::super::index::{self, ResolvedSession};
use super::super::ordering::{sort_session_agents, sort_session_tasks};
use super::super::protocol::{AgentToolActivitySummary, SessionDetail, SessionExtensionsPayload};
use super::activity::load_agent_activity_for;
use super::observer::load_observer_summary;
use super::signals::load_signals_for_resolved;
use super::summaries::summary_from_resolved;
use crate::daemon::db::DaemonDb;
use crate::errors::CliError;
use crate::session::types::{AgentRegistration, AgentStatus, SessionSignalRecord, SessionState};

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
    db: &DaemonDb,
) -> Result<SessionDetail, CliError> {
    build_session_detail(resolved, Some(db))
}

fn build_session_detail(
    resolved: &ResolvedSession,
    db: Option<&DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let mut agents = visible_session_agents(&resolved.state);
    sort_session_agents(&mut agents);

    let mut tasks: Vec<_> = resolved.state.tasks.values().cloned().collect();
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

    let mut tasks: Vec<_> = resolved.state.tasks.values().cloned().collect();
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
        .map(normalize_protocol_agent_status)
        .collect()
}

fn normalize_protocol_agent_status(mut agent: AgentRegistration) -> AgentRegistration {
    if agent.status == AgentStatus::Idle {
        agent.status = AgentStatus::Active;
    }
    agent
}

/// Build the expensive session detail extensions (signals, observer, activity).
///
/// # Errors
/// Returns [`CliError`] on filesystem or database read failures.
pub fn build_session_extensions(
    resolved: &ResolvedSession,
    db: Option<&DaemonDb>,
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

pub(crate) fn build_session_extensions_from_cached_runtime(
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
