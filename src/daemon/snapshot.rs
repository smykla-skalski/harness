use std::collections::BTreeMap;

use crate::agents::runtime::signal::{
    read_acknowledged_signals, read_acknowledgments, read_pending_signals,
};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::observe::types::ObserverState;
use crate::session::types::{
    SessionSignalRecord, SessionSignalStatus, SessionState, SessionStatus,
};

use super::index::{self, DiscoveredProject, ResolvedSession};
use super::protocol::{ObserverSummary, ProjectSummary, SessionDetail, SessionSummary};
use super::state;

/// Build summaries for all discovered projects.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn project_summaries() -> Result<Vec<ProjectSummary>, CliError> {
    let projects = index::discover_projects()?;
    let sessions = index::discover_sessions(true)?;
    let mut counts: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for session in sessions {
        let entry = counts
            .entry(session.project.project_id.clone())
            .or_insert((0, 0));
        entry.1 += 1;
        if session.state.status == SessionStatus::Active {
            entry.0 += 1;
        }
    }

    Ok(projects
        .into_iter()
        .map(|project| {
            let (active_session_count, total_session_count) =
                counts.get(&project.project_id).copied().unwrap_or((0, 0));
            ProjectSummary {
                project_id: project.project_id,
                name: project.name,
                project_dir: project.project_dir.map(|path| path.display().to_string()),
                context_root: project.context_root.display().to_string(),
                active_session_count,
                total_session_count,
            }
        })
        .collect())
}

/// Build summaries for all sessions across discovered projects.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn session_summaries(include_all: bool) -> Result<Vec<SessionSummary>, CliError> {
    let mut sessions: Vec<SessionSummary> = index::discover_sessions(include_all)?
        .into_iter()
        .map(|session| summary_from_resolved(&session))
        .collect();
    sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(sessions)
}

/// Build a rich session detail snapshot, then persist it into the daemon cache.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn session_detail(session_id: &str) -> Result<SessionDetail, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let detail = build_session_detail(&resolved)?;
    let _ = state::write_session_cache(&detail.session.project_id, session_id, &detail);
    Ok(detail)
}

fn build_session_detail(resolved: &ResolvedSession) -> Result<SessionDetail, CliError> {
    let mut agents: Vec<_> = resolved.state.agents.values().cloned().collect();
    agents.sort_by(|left, right| left.agent_id.cmp(&right.agent_id));

    let mut tasks: Vec<_> = resolved.state.tasks.values().cloned().collect();
    tasks.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));

    Ok(SessionDetail {
        session: summary_from_resolved(resolved),
        agents,
        tasks,
        signals: load_signals(&resolved.project, &resolved.state)?,
        observer: load_observer_summary(&resolved.project, &resolved.state)?,
    })
}

fn summary_from_resolved(resolved: &ResolvedSession) -> SessionSummary {
    SessionSummary {
        project_id: resolved.project.project_id.clone(),
        project_name: resolved.project.name.clone(),
        project_dir: resolved
            .project
            .project_dir
            .as_ref()
            .map(|path| path.display().to_string()),
        context_root: resolved.project.context_root.display().to_string(),
        session_id: resolved.state.session_id.clone(),
        context: resolved.state.context.clone(),
        status: resolved.state.status,
        created_at: resolved.state.created_at.clone(),
        updated_at: resolved.state.updated_at.clone(),
        last_activity_at: resolved.state.last_activity_at.clone(),
        leader_id: resolved.state.leader_id.clone(),
        observe_id: resolved.state.observe_id.clone(),
        metrics: resolved.state.metrics.clone(),
    }
}

fn load_observer_summary(
    project: &DiscoveredProject,
    state: &SessionState,
) -> Result<Option<ObserverSummary>, CliError> {
    let Some(observe_id) = state.observe_id.as_deref() else {
        return Ok(None);
    };
    let path = index::observe_snapshot_path(&project.context_root, observe_id);
    if !path.is_file() {
        return Ok(None);
    }
    let observer: ObserverState = read_json_typed(&path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "read observer snapshot {}: {error}",
            path.display()
        )))
    })?;
    Ok(Some(ObserverSummary {
        observe_id: observe_id.to_string(),
        last_scan_time: observer.last_scan_time,
        open_issue_count: observer.open_issues.len(),
        muted_code_count: observer.muted_codes.len(),
        active_worker_count: observer.active_workers.len(),
    }))
}

fn load_signals(
    project: &DiscoveredProject,
    state: &SessionState,
) -> Result<Vec<SessionSignalRecord>, CliError> {
    let mut signals = Vec::new();
    let root = index::signals_root(&project.context_root);
    for (agent_id, agent) in &state.agents {
        let signal_dir = root.join(&agent.runtime).join(&state.session_id);
        let pending = read_pending_signals(&signal_dir)?;
        let acknowledged = read_acknowledged_signals(&signal_dir)?;
        let acknowledgments = read_acknowledgments(&signal_dir)?;
        let acknowledgment_by_id: BTreeMap<String, _> = acknowledgments
            .into_iter()
            .map(|ack| (ack.signal_id.clone(), ack))
            .collect();

        for signal in pending {
            signals.push(SessionSignalRecord {
                runtime: agent.runtime.clone(),
                agent_id: agent_id.clone(),
                session_id: state.session_id.clone(),
                status: SessionSignalStatus::Pending,
                signal,
                acknowledgment: None,
            });
        }
        for signal in acknowledged {
            let acknowledgment = acknowledgment_by_id.get(&signal.signal_id).cloned();
            let status = acknowledgment
                .as_ref()
                .map_or(SessionSignalStatus::Pending, |ack| {
                    SessionSignalStatus::from_ack_result(ack.result)
                });
            signals.push(SessionSignalRecord {
                runtime: agent.runtime.clone(),
                agent_id: agent_id.clone(),
                session_id: state.session_id.clone(),
                status,
                signal,
                acknowledgment,
            });
        }
    }

    signals.sort_by(|left, right| right.signal.created_at.cmp(&left.signal.created_at));
    Ok(signals)
}
