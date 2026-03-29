use std::collections::BTreeMap;

use crate::agents::runtime::event::ConversationEventKind;
use crate::agents::runtime::signal::{
    read_acknowledged_signals, read_acknowledgments, read_pending_signals,
};
use crate::agents::runtime::signal_session_keys;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::observe::types::ObserverState;
use crate::session::types::{
    SessionSignalRecord, SessionSignalStatus, SessionState, SessionStatus,
};

use super::index::{self, DiscoveredProject, ResolvedSession};
use super::protocol::{
    AgentToolActivitySummary, ObserverActiveWorker, ObserverAgentSessionSummary,
    ObserverCycleSummary, ObserverOpenIssue, ObserverSummary, ProjectSummary, SessionDetail,
    SessionSummary,
};
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
        agent_activity: load_agent_activity(&resolved.project, &resolved.state)?,
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
        pending_leader_transfer: resolved.state.pending_leader_transfer.clone(),
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
        cycle_history: observer
            .cycle_history
            .into_iter()
            .map(|cycle| ObserverCycleSummary {
                timestamp: cycle.timestamp,
                from_line: cycle.from_line,
                to_line: cycle.to_line,
                new_issues: cycle.new_issues,
                resolved: cycle.resolved,
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

fn load_agent_activity(
    project: &DiscoveredProject,
    state: &SessionState,
) -> Result<Vec<AgentToolActivitySummary>, CliError> {
    let mut summaries = Vec::new();
    for (agent_id, agent) in &state.agents {
        let session_key = agent
            .agent_session_id
            .as_deref()
            .unwrap_or(&state.session_id);
        let events =
            index::load_conversation_events(project, &agent.runtime, session_key, agent_id)?;
        let mut summary = AgentToolActivitySummary {
            agent_id: agent_id.clone(),
            runtime: agent.runtime.clone(),
            tool_invocation_count: 0,
            tool_result_count: 0,
            tool_error_count: 0,
            latest_tool_name: None,
            latest_event_at: agent.last_activity_at.clone(),
            recent_tools: Vec::new(),
        };

        for event in events {
            match event.kind {
                ConversationEventKind::ToolInvocation { tool_name, .. } => {
                    summary.tool_invocation_count += 1;
                    record_tool_event(&mut summary, &tool_name, event.timestamp);
                }
                ConversationEventKind::ToolResult {
                    tool_name,
                    is_error,
                    ..
                } => {
                    summary.tool_result_count += 1;
                    if is_error {
                        summary.tool_error_count += 1;
                    }
                    record_tool_event(&mut summary, &tool_name, event.timestamp);
                }
                ConversationEventKind::Error { .. } => {
                    summary.tool_error_count += 1;
                    if let Some(timestamp) = event.timestamp {
                        summary.latest_event_at = Some(timestamp);
                    }
                }
                _ => {}
            }
        }

        summaries.push(summary);
    }
    summaries.sort_by(|left, right| left.agent_id.cmp(&right.agent_id));
    Ok(summaries)
}

fn record_tool_event(
    summary: &mut AgentToolActivitySummary,
    tool_name: &str,
    timestamp: Option<String>,
) {
    if let Some(timestamp) = timestamp {
        summary.latest_event_at = Some(timestamp);
    }
    if tool_name.is_empty() || tool_name == "unknown" {
        return;
    }

    summary.latest_tool_name = Some(tool_name.to_string());
    summary
        .recent_tools
        .retain(|existing| existing != tool_name);
    summary.recent_tools.insert(0, tool_name.to_string());
    if summary.recent_tools.len() > 5 {
        summary.recent_tools.truncate(5);
    }
}

fn load_signals(
    project: &DiscoveredProject,
    state: &SessionState,
) -> Result<Vec<SessionSignalRecord>, CliError> {
    let mut signals = Vec::new();
    let root = index::signals_root(&project.context_root);
    for (agent_id, agent) in &state.agents {
        let mut signals_by_id = BTreeMap::new();
        let mut acknowledgments_by_id = BTreeMap::new();
        for signal_session_id in
            signal_session_keys(&state.session_id, agent.agent_session_id.as_deref())
        {
            let signal_dir = root.join(&agent.runtime).join(signal_session_id);
            for signal in read_pending_signals(&signal_dir)? {
                signals_by_id
                    .entry(signal.signal_id.clone())
                    .or_insert((signal, false));
            }
            for signal in read_acknowledged_signals(&signal_dir)? {
                signals_by_id.insert(signal.signal_id.clone(), (signal, true));
            }
            for acknowledgment in read_acknowledgments(&signal_dir)? {
                acknowledgments_by_id
                    .entry(acknowledgment.signal_id.clone())
                    .or_insert(acknowledgment);
            }
        }

        for (signal, was_acknowledged) in signals_by_id.into_values() {
            let acknowledgment = acknowledgments_by_id.remove(&signal.signal_id);
            let status = acknowledgment.as_ref().map_or_else(
                || {
                    if was_acknowledged {
                        SessionSignalStatus::Acknowledged
                    } else {
                        SessionSignalStatus::Pending
                    }
                },
                |ack| SessionSignalStatus::from_ack_result(ack.result),
            );
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

    fn write_json_line(path: &Path, value: &impl serde::Serialize) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parent");
        }
        use std::io::Write as _;

        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .expect("open jsonl");
        writeln!(file, "{}", serde_json::to_string(value).expect("serialize")).expect("write");
    }

    fn sample_state(session_id: &str) -> SessionState {
        sample_state_for_runtime(session_id, "codex", "codex-session-1")
    }

    fn sample_state_for_runtime(
        session_id: &str,
        runtime: &str,
        runtime_session_id: &str,
    ) -> SessionState {
        let mut agents = BTreeMap::new();
        agents.insert(
            format!("{runtime}-worker"),
            AgentRegistration {
                agent_id: format!("{runtime}-worker"),
                name: format!("{} Worker", runtime.to_uppercase()),
                runtime: runtime.into(),
                role: SessionRole::Worker,
                capabilities: vec!["general".into()],
                joined_at: "2026-03-28T14:00:00Z".into(),
                updated_at: "2026-03-28T14:05:00Z".into(),
                status: AgentStatus::Active,
                agent_session_id: Some(runtime_session_id.into()),
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
            leader_id: Some(format!("{runtime}-worker")),
            archived_at: None,
            last_activity_at: Some("2026-03-28T14:05:00Z".into()),
            observe_id: Some("observe-sess-merge".into()),
            pending_leader_transfer: None,
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

                let transcript_path = context_root
                    .join("agents")
                    .join("sessions")
                    .join("codex")
                    .join("codex-session-1")
                    .join("raw.jsonl");
                write_json_line(
                    &transcript_path,
                    &serde_json::json!({
                        "timestamp": "2026-03-28T14:04:45Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_use",
                                "name": "Read",
                                "input": {"path": "src/daemon/snapshot.rs"},
                                "id": "call-read-1"
                            }]
                        }
                    }),
                );
                write_json_line(
                    &transcript_path,
                    &serde_json::json!({
                        "timestamp": "2026-03-28T14:04:46Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_result",
                                "tool_name": "Read",
                                "tool_use_id": "call-read-1",
                                "content": {"line_count": 32},
                                "is_error": false
                            }]
                        }
                    }),
                );

                let detail = session_detail(session_id).expect("detail");
                assert_eq!(detail.session.session_id, session_id);
                assert_eq!(detail.agents.len(), 1);
                assert_eq!(detail.signals.len(), 2);
                assert_eq!(detail.agent_activity.len(), 1);
                assert_eq!(detail.agent_activity[0].agent_id, "codex-worker");
                assert_eq!(detail.agent_activity[0].tool_invocation_count, 1);
                assert_eq!(detail.agent_activity[0].tool_result_count, 1);
                assert_eq!(detail.agent_activity[0].tool_error_count, 0);
                assert_eq!(
                    detail.agent_activity[0].latest_tool_name.as_deref(),
                    Some("Read")
                );
                assert_eq!(detail.agent_activity[0].recent_tools, vec!["Read"]);
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
                assert_eq!(
                    detail
                        .observer
                        .as_ref()
                        .expect("observer")
                        .resolved_issue_count,
                    1
                );
                assert_eq!(
                    detail
                        .observer
                        .as_ref()
                        .expect("observer")
                        .open_issues
                        .first()
                        .expect("open issue")
                        .summary,
                    "worker stalled"
                );
                assert_eq!(
                    detail
                        .observer
                        .as_ref()
                        .expect("observer")
                        .open_issues
                        .first()
                        .expect("open issue")
                        .fingerprint,
                    "fingerprint"
                );
                assert_eq!(
                    detail
                        .observer
                        .as_ref()
                        .expect("observer")
                        .open_issues
                        .first()
                        .expect("open issue")
                        .first_seen_line,
                    8
                );
                assert_eq!(
                    detail.observer.as_ref().expect("observer").muted_codes,
                    vec![IssueCode::AgentRepeatedError]
                );
                assert_eq!(
                    detail
                        .observer
                        .as_ref()
                        .expect("observer")
                        .active_workers
                        .first()
                        .and_then(|worker| worker.runtime.as_deref()),
                    Some("codex")
                );
                assert_eq!(
                    detail
                        .observer
                        .as_ref()
                        .expect("observer")
                        .active_workers
                        .first()
                        .and_then(|worker| worker.agent_id.as_deref()),
                    Some("codex-worker")
                );

                let cache_path = state::session_cache_path("project-alpha", session_id);
                assert!(cache_path.is_file());
            },
        );
    }

    #[test]
    fn session_detail_agent_activity_falls_back_to_ledger_for_copilot() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                let context_root = tmp.path().join("harness/projects/project-alpha");
                let session_id = "sess-copilot";
                let state_path = context_root
                    .join("orchestration")
                    .join("sessions")
                    .join(session_id)
                    .join("state.json");
                write_json(
                    &state_path,
                    &sample_state_for_runtime(session_id, "copilot", "copilot-session-1"),
                );

                let ledger_path = context_root.join("agents/ledger/events.jsonl");
                write_json_line(
                    &ledger_path,
                    &serde_json::json!({
                        "sequence": 1,
                        "recorded_at": "2026-03-28T14:04:45Z",
                        "agent": "copilot",
                        "session_id": "copilot-session-1",
                        "skill": "suite",
                        "event": "before_tool_use",
                        "hook": "guard-write",
                        "decision": "allow",
                        "payload": serde_json::json!({
                            "timestamp": "2026-03-28T14:04:45Z",
                            "message": {
                                "role": "assistant",
                                "content": [{
                                    "type": "tool_use",
                                    "name": "Read",
                                    "input": {"path": "README.md"},
                                    "id": "call-read-1",
                                }]
                            }
                        }),
                    }),
                );
                write_json_line(
                    &ledger_path,
                    &serde_json::json!({
                        "sequence": 2,
                        "recorded_at": "2026-03-28T14:04:46Z",
                        "agent": "copilot",
                        "session_id": "copilot-session-1",
                        "skill": "suite",
                        "event": "after_tool_use",
                        "hook": "verify-write",
                        "decision": "allow",
                        "payload": serde_json::json!({
                            "timestamp": "2026-03-28T14:04:46Z",
                            "message": {
                                "role": "assistant",
                                "content": [{
                                    "type": "tool_result",
                                    "tool_name": "Read",
                                    "tool_use_id": "call-read-1",
                                    "content": {"line_count": 12},
                                    "is_error": false,
                                }]
                            }
                        }),
                    }),
                );

                let detail = session_detail(session_id).expect("detail");
                assert_eq!(detail.agent_activity.len(), 1);
                assert_eq!(detail.agent_activity[0].agent_id, "copilot-worker");
                assert_eq!(detail.agent_activity[0].runtime, "copilot");
                assert_eq!(detail.agent_activity[0].tool_invocation_count, 1);
                assert_eq!(detail.agent_activity[0].tool_result_count, 1);
                assert_eq!(detail.agent_activity[0].tool_error_count, 0);
                assert_eq!(
                    detail.agent_activity[0].latest_tool_name.as_deref(),
                    Some("Read")
                );
            },
        );
    }
}
