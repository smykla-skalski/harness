use std::path::PathBuf;

use super::{
    BTreeMap, CURRENT_VERSION, CliError, CliErrorKind, DaemonClient, ResolvedRuntimeSessionAgent,
    SessionState, SessionStatus, protocol, runtime_session_matches_agent,
};
use crate::daemon::client::RuntimeSessionLookup;
use crate::session::types::SessionPolicy;

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
        project_name: detail.session.project_name.clone(),
        worktree_path: PathBuf::from(&detail.session.worktree_path),
        shared_path: PathBuf::from(&detail.session.shared_path),
        origin_path: PathBuf::from(&detail.session.origin_path),
        branch_ref: detail.session.branch_ref.clone(),
        title: detail.session.title.clone(),
        context: detail.session.context.clone(),
        status: detail.session.status,
        policy: SessionPolicy::default(),
        created_at: detail.session.created_at.clone(),
        updated_at: detail.session.updated_at.clone(),
        agents,
        tasks,
        leader_id: detail.session.leader_id.clone(),
        archived_at: None,
        last_activity_at: detail.session.last_activity_at.clone(),
        observe_id: detail.session.observe_id.clone(),
        pending_leader_transfer: detail.session.pending_leader_transfer.clone(),
        external_origin: detail.session.external_origin.as_ref().map(PathBuf::from),
        adopted_at: detail.session.adopted_at.clone(),
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
        project_name: summary.project_name.clone(),
        worktree_path: PathBuf::from(&summary.worktree_path),
        shared_path: PathBuf::from(&summary.shared_path),
        origin_path: PathBuf::from(&summary.origin_path),
        branch_ref: summary.branch_ref.clone(),
        title: summary.title.clone(),
        context: summary.context.clone(),
        status: summary.status,
        policy: SessionPolicy::default(),
        created_at: summary.created_at.clone(),
        updated_at: summary.updated_at.clone(),
        agents: BTreeMap::new(),
        tasks: BTreeMap::new(),
        leader_id: summary.leader_id.clone(),
        archived_at: None,
        last_activity_at: summary.last_activity_at.clone(),
        observe_id: summary.observe_id.clone(),
        pending_leader_transfer: summary.pending_leader_transfer.clone(),
        external_origin: summary.external_origin.as_ref().map(PathBuf::from),
        adopted_at: summary.adopted_at.clone(),
        metrics: summary.metrics.clone(),
    }
}

pub(crate) fn resolve_runtime_session_via_daemon(
    client: &DaemonClient,
    runtime_name: &str,
    runtime_session_id: &str,
) -> Result<Option<ResolvedRuntimeSessionAgent>, CliError> {
    match client.resolve_runtime_session(runtime_name, runtime_session_id)? {
        RuntimeSessionLookup::Resolved(agent) => Ok(Some(agent)),
        RuntimeSessionLookup::NotFound => Ok(None),
        RuntimeSessionLookup::EndpointUnavailable => {
            resolve_runtime_session_via_legacy_fanout(client, runtime_name, runtime_session_id)
        }
    }
}

/// Legacy resolver used only when the daemon predates
/// `/v1/runtime-sessions/resolve`. Kept intact for seamless upgrades -
/// delete once the minimum supported daemon version ships the new endpoint.
fn resolve_runtime_session_via_legacy_fanout(
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::types::SessionMetrics;

    fn summary_fixture() -> protocol::SessionSummary {
        protocol::SessionSummary {
            project_id: "proj-id".into(),
            project_name: "demo".into(),
            project_dir: Some("/origin".into()),
            context_root: "/origin".into(),
            worktree_path: "/data/sessions/demo/abc12345/workspace".into(),
            shared_path: "/data/sessions/demo/abc12345/memory".into(),
            origin_path: "/origin".into(),
            branch_ref: "harness/abc12345".into(),
            session_id: "abc12345".into(),
            title: "t".into(),
            context: "c".into(),
            status: SessionStatus::Active,
            created_at: "2026-04-20T00:00:00Z".into(),
            updated_at: "2026-04-20T00:00:00Z".into(),
            last_activity_at: None,
            leader_id: None,
            observe_id: None,
            pending_leader_transfer: None,
            external_origin: None,
            adopted_at: None,
            metrics: SessionMetrics::default(),
        }
    }

    #[test]
    fn summary_to_session_state_forwards_workspace_fields() {
        let state = summary_to_session_state(&summary_fixture());
        assert_eq!(state.branch_ref, "harness/abc12345");
        assert_eq!(
            state.worktree_path,
            PathBuf::from("/data/sessions/demo/abc12345/workspace")
        );
        assert_eq!(
            state.shared_path,
            PathBuf::from("/data/sessions/demo/abc12345/memory")
        );
        assert_eq!(state.origin_path, PathBuf::from("/origin"));
    }

    #[test]
    fn summary_to_session_state_preserves_adoption_metadata() {
        let mut summary = summary_fixture();
        summary.external_origin = Some("/external/session-root".into());
        summary.adopted_at = Some("2026-04-20T02:03:04Z".into());

        let state = summary_to_session_state(&summary);

        assert_eq!(
            state.external_origin,
            Some(PathBuf::from("/external/session-root"))
        );
        assert_eq!(state.adopted_at.as_deref(), Some("2026-04-20T02:03:04Z"));
    }

    #[test]
    fn detail_to_session_state_forwards_workspace_fields() {
        let detail = protocol::SessionDetail {
            session: summary_fixture(),
            agents: Vec::new(),
            tasks: Vec::new(),
            signals: Vec::new(),
            observer: None,
            agent_activity: Vec::new(),
        };
        let state = detail_to_session_state(&detail);
        assert_eq!(state.branch_ref, "harness/abc12345");
        assert_eq!(
            state.worktree_path,
            PathBuf::from("/data/sessions/demo/abc12345/workspace")
        );
        assert_eq!(
            state.shared_path,
            PathBuf::from("/data/sessions/demo/abc12345/memory")
        );
        assert_eq!(state.origin_path, PathBuf::from("/origin"));
    }

    #[test]
    fn detail_to_session_state_preserves_adoption_metadata() {
        let mut summary = summary_fixture();
        summary.external_origin = Some("/external/session-root".into());
        summary.adopted_at = Some("2026-04-20T02:03:04Z".into());

        let detail = protocol::SessionDetail {
            session: summary,
            agents: Vec::new(),
            tasks: Vec::new(),
            signals: Vec::new(),
            observer: None,
            agent_activity: Vec::new(),
        };

        let state = detail_to_session_state(&detail);

        assert_eq!(
            state.external_origin,
            Some(PathBuf::from("/external/session-root"))
        );
        assert_eq!(state.adopted_at.as_deref(), Some("2026-04-20T02:03:04Z"));
    }
}
