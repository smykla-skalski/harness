use super::{
    BTreeMap, CURRENT_VERSION, CliError, CliErrorKind, DaemonClient, ResolvedRuntimeSessionAgent,
    SessionState, SessionStatus, protocol, runtime_session_matches_agent,
};

pub(crate) fn detail_to_session_state(detail: &protocol::SessionDetail) -> SessionState {
    let agents = detail
        .agents
        .iter()
        .map(|agent| (agent.agent_id.clone(), agent.clone()))
        .collect();
    let tasks = detail
        .tasks
        .iter()
        .map(|task| (task.task_id.clone(), task.clone()))
        .collect();
    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 0,
        session_id: detail.session.session_id.clone(),
        title: detail.session.title.clone(),
        context: detail.session.context.clone(),
        status: detail.session.status,
        created_at: detail.session.created_at.clone(),
        updated_at: detail.session.updated_at.clone(),
        agents,
        tasks,
        leader_id: detail.session.leader_id.clone(),
        archived_at: None,
        last_activity_at: detail.session.last_activity_at.clone(),
        observe_id: detail.session.observe_id.clone(),
        pending_leader_transfer: detail.session.pending_leader_transfer.clone(),
        metrics: detail.session.metrics.clone(),
    }
}

/// Reconstruct a minimal `SessionState` from a daemon `SessionSummary`.
///
/// The summary doesn't contain agents or tasks - only the session-level
/// fields and metrics. This is sufficient for list display.
pub(crate) fn summary_to_session_state(summary: &protocol::SessionSummary) -> SessionState {
    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 0,
        session_id: summary.session_id.clone(),
        title: summary.title.clone(),
        context: summary.context.clone(),
        status: summary.status,
        created_at: summary.created_at.clone(),
        updated_at: summary.updated_at.clone(),
        agents: BTreeMap::new(),
        tasks: BTreeMap::new(),
        leader_id: summary.leader_id.clone(),
        archived_at: None,
        last_activity_at: summary.last_activity_at.clone(),
        observe_id: summary.observe_id.clone(),
        pending_leader_transfer: summary.pending_leader_transfer.clone(),
        metrics: summary.metrics.clone(),
    }
}

pub(crate) fn resolve_runtime_session_via_daemon(
    client: &DaemonClient,
    runtime_name: &str,
    runtime_session_id: &str,
) -> Result<Option<ResolvedRuntimeSessionAgent>, CliError> {
    let summaries = client.list_sessions()?;
    let mut matches = Vec::new();
    for summary in &summaries {
        if summary.status != SessionStatus::Active {
            continue;
        }
        let Ok(detail) = client.get_session_detail(&summary.session_id) else {
            continue;
        };
        for agent in &detail.agents {
            if !agent.status.is_alive() || agent.runtime != runtime_name {
                continue;
            }
            if runtime_session_matches_agent(&summary.session_id, agent, runtime_session_id) {
                matches.push(ResolvedRuntimeSessionAgent {
                    orchestration_session_id: summary.session_id.clone(),
                    agent_id: agent.agent_id.clone(),
                });
            }
        }
    }
    match matches.len() {
        0 => Ok(None),
        1 => Ok(matches.into_iter().next()),
        _ => Err(CliErrorKind::session_ambiguous(format!(
            "runtime session '{runtime_session_id}' for runtime '{runtime_name}' maps to multiple orchestration sessions"
        ))
        .into()),
    }
}
