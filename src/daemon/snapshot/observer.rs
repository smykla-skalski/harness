use super::super::index::{self, DiscoveredProject};
use super::super::protocol::{
    ObserverActiveWorker, ObserverAgentSessionSummary, ObserverOpenIssue, ObserverSummary,
};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::observe::types::ObserverState;
use crate::session::types::SessionState;

pub(super) fn load_observer_summary(
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
        last_sweep_at: observer.last_sweep_at,
        open_issue_count: observer.open_issues.len(),
        resolved_issue_count: observer.resolved_issue_ids.len(),
        muted_code_count: observer.muted_codes.len(),
        active_worker_count: observer.active_workers.len(),
        open_issues: observer
            .open_issues
            .into_iter()
            .map(|issue| ObserverOpenIssue {
                issue_id: issue.issue_id,
                code: issue.code,
                severity: issue.severity,
                category: issue.category,
                summary: issue.summary,
                fingerprint: issue.fingerprint,
                first_seen_line: issue.first_seen_line,
                occurrence_count: issue.occurrence_count,
                last_seen_line: issue.last_seen_line,
                fix_safety: issue.fix_safety,
                evidence_excerpt: issue.evidence_excerpt,
            })
            .collect(),
        muted_codes: observer.muted_codes,
        active_workers: observer
            .active_workers
            .into_iter()
            .map(|worker| ObserverActiveWorker {
                issue_id: worker.issue_id,
                target_file: worker.target_file,
                started_at: worker.started_at,
                runtime: worker
                    .agent_id
                    .as_ref()
                    .and_then(|agent_id| state.agents.get(agent_id))
                    .map(|agent| agent.runtime.clone()),
                agent_id: worker.agent_id,
            })
            .collect(),
        agent_sessions: observer
            .agent_sessions
            .into_iter()
            .map(|agent| ObserverAgentSessionSummary {
                agent_id: agent.agent_id,
                runtime: agent.runtime,
                log_path: agent.log_path,
                cursor: agent.cursor,
                last_activity: agent.last_activity,
            })
            .collect(),
    }))
}
