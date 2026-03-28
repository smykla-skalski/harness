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

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::path::Path;

    use fs_err as fs;
    use tempfile::tempdir;

    use crate::agents::runtime::signal::{
        AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
        acknowledge_signal, write_signal_file,
    };
    use crate::observe::types::{
        ActiveWorker, CycleRecord, FixSafety, IssueCategory, IssueCode, IssueSeverity,
        ObserverState, OpenIssue,
    };
    use crate::session::types::{
        AgentRegistration, AgentStatus, CURRENT_VERSION, SessionMetrics, SessionRole,
        SessionSignalStatus, SessionState, SessionStatus,
    };

    fn write_json(path: &Path, value: &impl serde::Serialize) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parent");
        }
        fs::write(
            path,
            serde_json::to_string_pretty(value).expect("serialize"),
        )
        .expect("write");
    }

    fn sample_state(session_id: &str) -> SessionState {
        let mut agents = BTreeMap::new();
        agents.insert(
            "codex-worker".into(),
            AgentRegistration {
                agent_id: "codex-worker".into(),
                name: "Codex Worker".into(),
                runtime: "codex".into(),
                role: SessionRole::Worker,
                capabilities: vec!["general".into()],
                joined_at: "2026-03-28T14:00:00Z".into(),
                updated_at: "2026-03-28T14:05:00Z".into(),
                status: AgentStatus::Active,
                agent_session_id: Some("codex-session-1".into()),
                last_activity_at: Some("2026-03-28T14:05:00Z".into()),
                current_task_id: None,
                runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
            },
        );

        let mut state = SessionState {
            schema_version: CURRENT_VERSION,
            state_version: 0,
            session_id: session_id.into(),
            context: "test goal".into(),
            status: SessionStatus::Active,
            created_at: "2026-03-28T14:00:00Z".into(),
            updated_at: "2026-03-28T14:05:00Z".into(),
            agents,
            tasks: BTreeMap::new(),
            leader_id: Some("codex-worker".into()),
            archived_at: None,
            last_activity_at: Some("2026-03-28T14:05:00Z".into()),
            observe_id: Some("observe-sess-merge".into()),
            metrics: SessionMetrics::default(),
        };
        state.metrics = SessionMetrics::recalculate(&state);
        state
    }

    fn sample_signal(signal_id: &str, message: &str) -> Signal {
        Signal {
            signal_id: signal_id.into(),
            version: 1,
            created_at: "2026-03-28T14:03:00Z".into(),
            expires_at: "2026-03-28T14:13:00Z".into(),
            source_agent: "leader-claude".into(),
            command: "inject_context".into(),
            priority: SignalPriority::High,
            payload: SignalPayload {
                message: message.into(),
                action_hint: Some("refresh the cockpit".into()),
                related_files: vec!["src/daemon/snapshot.rs".into()],
                metadata: serde_json::json!({"source": "test"}),
            },
            delivery: DeliveryConfig {
                max_retries: 3,
                retry_count: 0,
                idempotency_key: None,
            },
        }
    }

    fn observer_state(session_id: &str) -> ObserverState {
        ObserverState {
            schema_version: 1,
            state_version: 0,
            session_id: session_id.into(),
            project_hint: Some("project-alpha".into()),
            cursor: 42,
            last_scan_time: "2026-03-28T14:04:00Z".into(),
            open_issues: vec![OpenIssue {
                issue_id: "issue-1".into(),
                code: IssueCode::AgentStalledProgress,
                fingerprint: "fingerprint".into(),
                first_seen_line: 8,
                last_seen_line: 10,
                occurrence_count: 2,
                severity: IssueSeverity::Critical,
                category: IssueCategory::AgentCoordination,
                summary: "worker stalled".into(),
                fix_safety: FixSafety::TriageRequired,
            }],
            resolved_issue_ids: vec!["issue-0".into()],
            issue_attempts: Vec::new(),
            muted_codes: vec![IssueCode::AgentRepeatedError],
            cycle_history: vec![CycleRecord {
                timestamp: "2026-03-28T14:04:00Z".into(),
                from_line: 0,
                to_line: 42,
                new_issues: 1,
                resolved: 0,
            }],
            baseline_issue_ids: Vec::new(),
            active_workers: vec![ActiveWorker {
                issue_id: "issue-1".into(),
                target_file: "src/daemon/snapshot.rs".into(),
                started_at: "2026-03-28T14:04:30Z".into(),
                agent_id: Some("codex-worker".into()),
            }],
            agent_sessions: Vec::new(),
        }
    }

    #[test]
    fn session_detail_includes_signals_observer_and_cache() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                let context_root = tmp.path().join("harness/projects/project-alpha");
                let session_id = "sess-merge";
                let state_path = context_root
                    .join("orchestration")
                    .join("sessions")
                    .join(session_id)
                    .join("state.json");
                write_json(&state_path, &sample_state(session_id));

                let signal_dir = context_root.join("agents/signals/codex/sess-merge");
                write_signal_file(&signal_dir, &sample_signal("sig-pending", "keep going"))
                    .expect("write pending signal");

                let signal = sample_signal("sig-acked", "merged timeline");
                write_signal_file(&signal_dir, &signal).expect("write acked signal");
                acknowledge_signal(
                    &signal_dir,
                    &SignalAck {
                        signal_id: "sig-acked".into(),
                        acknowledged_at: "2026-03-28T14:03:10Z".into(),
                        result: AckResult::Accepted,
                        agent: "codex-worker".into(),
                        session_id: session_id.into(),
                        details: Some("loaded".into()),
                    },
                )
                .expect("ack signal");

                let observer_path =
                    context_root.join("agents/observe/observe-sess-merge/snapshot.json");
                write_json(&observer_path, &observer_state(session_id));

                let detail = session_detail(session_id).expect("detail");
                assert_eq!(detail.session.session_id, session_id);
                assert_eq!(detail.agents.len(), 1);
                assert_eq!(detail.signals.len(), 2);
                assert_eq!(
                    detail
                        .signals
                        .iter()
                        .filter(|record| record.status == SessionSignalStatus::Acknowledged)
                        .count(),
                    1
                );
                assert_eq!(
                    detail.observer.as_ref().expect("observer").open_issue_count,
                    1
                );
                assert_eq!(
                    detail
                        .observer
                        .as_ref()
                        .expect("observer")
                        .active_worker_count,
                    1
                );

                let cache_path = state::session_cache_path("project-alpha", session_id);
                assert!(cache_path.is_file());
            },
        );
    }
}
