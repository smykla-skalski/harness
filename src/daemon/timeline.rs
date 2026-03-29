use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use crate::agents::runtime::signal::{
    AckResult, Signal, SignalAck, read_acknowledged_signals, read_acknowledgments,
};
use serde_json::to_value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::observe::types::ObserverState;
use crate::session::types::{
    SessionRole, SessionState, SessionTransition, TaskCheckpoint, TaskSeverity, TaskStatus,
};

use super::index;
use super::protocol::TimelineEntry;

/// Build a merged session timeline from session transitions and task checkpoints.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn session_timeline(session_id: &str) -> Result<Vec<TimelineEntry>, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let mut entries = Vec::new();
    let mut logged_signal_acks = HashSet::new();
    let mut sent_signals = BTreeMap::new();

    for log_entry in index::load_log_entries(&resolved.project, session_id)? {
        if let SessionTransition::SignalAcknowledged { signal_id, .. } = &log_entry.transition {
            logged_signal_acks.insert(signal_id.clone());
        }
        if let SessionTransition::SignalSent {
            signal_id,
            agent_id,
            command,
        } = &log_entry.transition
        {
            sent_signals.insert(
                signal_id.clone(),
                LoggedSignal {
                    agent_id: agent_id.clone(),
                    command: command.clone(),
                },
            );
        }
        let (kind, task_id, summary) = transition_summary(&log_entry.transition);
        let payload = timeline_payload(&log_entry.transition, "session transition")?;
        entries.push(TimelineEntry {
            entry_id: format!("log-{}", log_entry.sequence),
            recorded_at: log_entry.recorded_at,
            kind: kind.to_string(),
            session_id: log_entry.session_id,
            agent_id: log_entry.actor_id,
            task_id,
            summary,
            payload,
        });
    }

    for task_id in resolved.state.tasks.keys() {
        for checkpoint in index::load_task_checkpoints(&resolved.project, session_id, task_id)? {
            entries.push(checkpoint_entry(session_id, &checkpoint)?);
        }
    }

    entries.extend(signal_ack_entries(
        &resolved.state,
        &resolved.project.context_root,
        &sent_signals,
        &logged_signal_acks,
    )?);

    if let Some(observer_entry) =
        observer_snapshot_entry(&resolved.state, &resolved.project.context_root)?
    {
        entries.push(observer_entry);
    }

    entries.sort_by(|left, right| right.recorded_at.cmp(&left.recorded_at));
    Ok(entries)
}

fn checkpoint_entry(
    session_id: &str,
    checkpoint: &TaskCheckpoint,
) -> Result<TimelineEntry, CliError> {
    let payload = timeline_payload(checkpoint, "task checkpoint")?;
    Ok(TimelineEntry {
        entry_id: checkpoint.checkpoint_id.clone(),
        recorded_at: checkpoint.recorded_at.clone(),
        kind: "task_checkpoint".into(),
        session_id: session_id.to_string(),
        agent_id: checkpoint.actor_id.clone(),
        task_id: Some(checkpoint.task_id.clone()),
        summary: format!(
            "Checkpoint {}%: {}",
            checkpoint.progress, checkpoint.summary
        ),
        payload,
    })
}

fn signal_ack_entries(
    state: &SessionState,
    context_root: &Path,
    sent_signals: &BTreeMap<String, LoggedSignal>,
    logged_signal_acks: &HashSet<String>,
) -> Result<Vec<TimelineEntry>, CliError> {
    let mut entries = Vec::new();
    let signals_root = index::signals_root(context_root);
    let runtimes: HashSet<_> = state
        .agents
        .values()
        .map(|agent| agent.runtime.as_str())
        .collect();

    for runtime in runtimes {
        let signal_dir = signals_root.join(runtime).join(&state.session_id);
        let acknowledgments = read_acknowledgments(&signal_dir)?;
        let signals: BTreeMap<String, Signal> = read_acknowledged_signals(&signal_dir)?
            .into_iter()
            .map(|signal| (signal.signal_id.clone(), signal))
            .collect();

        for acknowledgment in acknowledgments {
            if logged_signal_acks.contains(&acknowledgment.signal_id) {
                continue;
            }
            let signal = signals.get(&acknowledgment.signal_id);
            let logged_signal = sent_signals.get(&acknowledgment.signal_id);
            entries.push(signal_ack_entry(
                &state.session_id,
                runtime,
                logged_signal,
                signal,
                &acknowledgment,
            )?);
        }
    }

    Ok(entries)
}

fn signal_ack_entry(
    session_id: &str,
    runtime: &str,
    logged_signal: Option<&LoggedSignal>,
    signal: Option<&Signal>,
    acknowledgment: &SignalAck,
) -> Result<TimelineEntry, CliError> {
    let payload = timeline_payload(
        &serde_json::json!({
            "logged_signal": logged_signal,
            "signal": signal,
            "acknowledgment": acknowledgment,
        }),
        "signal acknowledgment",
    )?;
    let agent_id = logged_signal.map_or(runtime, |logged_signal| logged_signal.agent_id.as_str());
    let command = signal
        .map(|signal| signal.command.as_str())
        .or_else(|| logged_signal.map(|logged_signal| logged_signal.command.as_str()));
    let summary = command.map_or_else(
        || {
            format!(
                "{} acknowledged by {}: {:?}",
                acknowledgment.signal_id, agent_id, acknowledgment.result
            )
        },
        |command| {
            format!(
                "{} acknowledged by {}: {:?} ({command})",
                acknowledgment.signal_id, agent_id, acknowledgment.result
            )
        },
    );

    Ok(TimelineEntry {
        entry_id: format!("signal-ack-{}", acknowledgment.signal_id),
        recorded_at: acknowledgment.acknowledged_at.clone(),
        kind: "signal_acknowledged".into(),
        session_id: session_id.to_string(),
        agent_id: Some(agent_id.to_string()),
        task_id: None,
        summary,
        payload,
    })
}

fn observer_snapshot_entry(
    state: &SessionState,
    context_root: &Path,
) -> Result<Option<TimelineEntry>, CliError> {
    let Some(observe_id) = state.observe_id.as_deref() else {
        return Ok(None);
    };
    let path = index::observe_snapshot_path(context_root, observe_id);
    if !path.is_file() {
        return Ok(None);
    }

    let observer: ObserverState = read_json_typed(&path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "read observer snapshot {}: {error}",
            path.display()
        )))
    })?;
    if observer.last_scan_time.is_empty() {
        return Ok(None);
    }

    let payload = timeline_payload(&observer, "observer snapshot")?;
    Ok(Some(TimelineEntry {
        entry_id: format!("observe-snapshot-{observe_id}"),
        recorded_at: observer.last_scan_time.clone(),
        kind: "observe_snapshot".into(),
        session_id: state.session_id.clone(),
        agent_id: None,
        task_id: None,
        summary: format!(
            "Observe scan: {} open, {} active workers, {} muted codes",
            observer.open_issues.len(),
            observer.active_workers.len(),
            observer.muted_codes.len()
        ),
        payload,
    }))
}

#[derive(Debug, Clone, serde::Serialize)]
struct LoggedSignal {
    agent_id: String,
    command: String,
}

fn timeline_payload(
    value: &impl serde::Serialize,
    label: &str,
) -> Result<serde_json::Value, CliError> {
    to_value(value).map_err(|error| {
        CliError::from(CliErrorKind::workflow_serialize(format!(
            "serialize {label} for timeline: {error}"
        )))
    })
}

fn transition_summary(transition: &SessionTransition) -> (&'static str, Option<String>, String) {
    match transition {
        SessionTransition::SessionStarted { context } => (
            "session_started",
            None,
            format!("Session started: {context}"),
        ),
        SessionTransition::SessionEnded => ("session_ended", None, "Session ended".into()),
        SessionTransition::AgentJoined {
            agent_id,
            role,
            runtime,
        } => agent_joined_summary(agent_id, *role, runtime),
        SessionTransition::AgentRemoved { agent_id } => agent_removed_summary(agent_id),
        SessionTransition::RoleChanged { agent_id, from, to } => {
            role_changed_summary(agent_id, *from, *to)
        }
        SessionTransition::LeaderTransferRequested { from, to } => {
            leader_transfer_requested_summary(from, to)
        }
        SessionTransition::LeaderTransferConfirmed {
            from,
            to,
            confirmed_by,
        } => leader_transfer_confirmed_summary(from, to, confirmed_by),
        SessionTransition::LeaderTransferred { from, to } => leader_transferred_summary(from, to),
        SessionTransition::TaskCreated {
            task_id,
            title,
            severity,
        } => task_created_summary(task_id, title, *severity),
        SessionTransition::ObserveTaskCreated {
            task_id,
            title,
            severity,
            issue_id,
        } => observe_task_created_summary(task_id, title, *severity, issue_id.as_deref()),
        SessionTransition::TaskAssigned { task_id, agent_id } => {
            task_assigned_summary(task_id, agent_id)
        }
        SessionTransition::TaskStatusChanged { task_id, from, to } => {
            task_status_changed_summary(task_id, *from, *to)
        }
        SessionTransition::TaskCheckpointRecorded {
            task_id,
            checkpoint_id,
            progress,
        } => task_checkpoint_recorded_summary(task_id, checkpoint_id, *progress),
        SessionTransition::SignalSent {
            signal_id,
            agent_id,
            command,
        } => signal_sent_summary(signal_id, agent_id, command),
        SessionTransition::SignalAcknowledged {
            signal_id,
            agent_id,
            result,
        } => signal_acknowledged_summary(signal_id, agent_id, *result),
    }
}

fn agent_joined_summary(
    agent_id: &str,
    role: SessionRole,
    runtime: &str,
) -> (&'static str, Option<String>, String) {
    (
        "agent_joined",
        None,
        format!("{agent_id} joined as {role:?} ({runtime})"),
    )
}

fn agent_removed_summary(agent_id: &str) -> (&'static str, Option<String>, String) {
    ("agent_removed", None, format!("{agent_id} removed"))
}

fn role_changed_summary(
    agent_id: &str,
    from: SessionRole,
    to: SessionRole,
) -> (&'static str, Option<String>, String) {
    (
        "role_changed",
        None,
        format!("{agent_id}: {from:?} -> {to:?}"),
    )
}

fn leader_transfer_requested_summary(
    from: &str,
    to: &str,
) -> (&'static str, Option<String>, String) {
    (
        "leader_transfer_requested",
        None,
        format!("Leadership transfer requested: {from} -> {to}"),
    )
}

fn leader_transfer_confirmed_summary(
    from: &str,
    to: &str,
    confirmed_by: &str,
) -> (&'static str, Option<String>, String) {
    (
        "leader_transfer_confirmed",
        None,
        format!("Leadership transfer confirmed by {confirmed_by}: {from} -> {to}"),
    )
}

fn leader_transferred_summary(from: &str, to: &str) -> (&'static str, Option<String>, String) {
    (
        "leader_transferred",
        None,
        format!("Leadership transferred: {from} -> {to}"),
    )
}

fn task_created_summary(
    task_id: &str,
    title: &str,
    severity: TaskSeverity,
) -> (&'static str, Option<String>, String) {
    (
        "task_created",
        Some(task_id.to_string()),
        format!("{task_id} created [{severity:?}]: {title}"),
    )
}

fn observe_task_created_summary(
    task_id: &str,
    title: &str,
    severity: TaskSeverity,
    issue_id: Option<&str>,
) -> (&'static str, Option<String>, String) {
    (
        "observe_task_created",
        Some(task_id.to_string()),
        format!(
            "{task_id} created from observe [{severity:?}]: {title}{}",
            issue_id.map_or_else(String::new, |id| format!(" ({id})"))
        ),
    )
}

fn task_assigned_summary(task_id: &str, agent_id: &str) -> (&'static str, Option<String>, String) {
    (
        "task_assigned",
        Some(task_id.to_string()),
        format!("{task_id} assigned to {agent_id}"),
    )
}

fn task_status_changed_summary(
    task_id: &str,
    from: TaskStatus,
    to: TaskStatus,
) -> (&'static str, Option<String>, String) {
    (
        "task_status_changed",
        Some(task_id.to_string()),
        format!("{task_id}: {from:?} -> {to:?}"),
    )
}

fn task_checkpoint_recorded_summary(
    task_id: &str,
    checkpoint_id: &str,
    progress: u8,
) -> (&'static str, Option<String>, String) {
    (
        "task_checkpoint_recorded",
        Some(task_id.to_string()),
        format!("{task_id} checkpoint {checkpoint_id} at {progress}%"),
    )
}

fn signal_sent_summary(
    signal_id: &str,
    agent_id: &str,
    command: &str,
) -> (&'static str, Option<String>, String) {
    (
        "signal_sent",
        None,
        format!("{signal_id} sent to {agent_id}: {command}"),
    )
}

fn signal_acknowledged_summary(
    signal_id: &str,
    agent_id: &str,
    result: AckResult,
) -> (&'static str, Option<String>, String) {
    (
        "signal_acknowledged",
        None,
        format!("{signal_id} acknowledged by {agent_id}: {result:?}"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    use fs_err as fs;
    use tempfile::tempdir;

    use crate::agents::runtime::RuntimeCapabilities;
    use crate::agents::runtime::signal::{
        AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
        acknowledge_signal, write_signal_file,
    };
    use crate::observe::types::{
        ActiveWorker, CycleRecord, FixSafety, IssueCategory, IssueCode, IssueSeverity,
        ObserverState, OpenIssue,
    };
    use crate::session::types::{
        AgentRegistration, AgentStatus, CURRENT_VERSION, SessionMetrics, SessionRole, SessionState,
        SessionStatus, TaskSeverity, TaskStatus, WorkItem,
    };

    fn write_json(path: &std::path::Path, value: &impl serde::Serialize) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parent");
        }
        fs::write(
            path,
            serde_json::to_string_pretty(value).expect("serialize"),
        )
        .expect("write");
    }

    fn write_json_line(path: &std::path::Path, value: &impl serde::Serialize) {
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
                current_task_id: Some("task-1".into()),
                runtime_capabilities: RuntimeCapabilities::default(),
            },
        );
        let mut tasks = BTreeMap::new();
        tasks.insert(
            "task-1".into(),
            WorkItem {
                task_id: "task-1".into(),
                title: "finish cockpit".into(),
                context: Some("merge timeline entries".into()),
                severity: TaskSeverity::High,
                status: TaskStatus::InProgress,
                assigned_to: Some("worker-codex".into()),
                created_at: "2026-03-28T14:00:00Z".into(),
                updated_at: "2026-03-28T14:05:00Z".into(),
                created_by: Some("leader-claude".into()),
                notes: Vec::new(),
                suggested_fix: None,
                source: crate::session::types::TaskSource::Manual,
                blocked_reason: None,
                completed_at: None,
                checkpoint_summary: None,
            },
        );

        SessionState {
            schema_version: CURRENT_VERSION,
            state_version: 0,
            session_id: session_id.into(),
            context: "test goal".into(),
            status: SessionStatus::Active,
            created_at: "2026-03-28T14:00:00Z".into(),
            updated_at: "2026-03-28T14:05:00Z".into(),
            agents,
            tasks,
            leader_id: Some("leader-claude".into()),
            archived_at: None,
            last_activity_at: Some("2026-03-28T14:05:00Z".into()),
            observe_id: Some("observe-sess-merge".into()),
            pending_leader_transfer: None,
            metrics: SessionMetrics::default(),
        }
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
                related_files: vec!["src/daemon/timeline.rs".into()],
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
                target_file: "src/daemon/timeline.rs".into(),
                started_at: "2026-03-28T14:04:30Z".into(),
                agent_id: Some("codex-worker".into()),
            }],
            agent_sessions: Vec::new(),
        }
    }

    #[test]
    fn session_timeline_merges_log_checkpoint_signal_and_observer_entries() {
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

                let log_entry = crate::session::types::SessionLogEntry {
                    sequence: 1,
                    recorded_at: "2026-03-28T14:01:00Z".into(),
                    session_id: session_id.into(),
                    transition: SessionTransition::TaskCreated {
                        task_id: "task-1".into(),
                        title: "finish cockpit".into(),
                        severity: TaskSeverity::High,
                    },
                    actor_id: Some("leader-claude".into()),
                    reason: None,
                };
                let log_path = context_root
                    .join("orchestration")
                    .join("sessions")
                    .join(session_id)
                    .join("log.jsonl");
                write_json_line(&log_path, &log_entry);
                write_json_line(
                    &log_path,
                    &crate::session::types::SessionLogEntry {
                        sequence: 2,
                        recorded_at: "2026-03-28T14:03:00Z".into(),
                        session_id: session_id.into(),
                        transition: SessionTransition::SignalSent {
                            signal_id: "sig-acked".into(),
                            agent_id: "codex-worker".into(),
                            command: "inject_context".into(),
                        },
                        actor_id: Some("leader-claude".into()),
                        reason: None,
                    },
                );

                let checkpoint = TaskCheckpoint {
                    checkpoint_id: "task-1-cp-1".into(),
                    task_id: "task-1".into(),
                    recorded_at: "2026-03-28T14:06:00Z".into(),
                    actor_id: Some("worker-codex".into()),
                    summary: "timeline rows are live-backed".into(),
                    progress: 70,
                };
                let checkpoint_path = context_root
                    .join("orchestration")
                    .join("sessions")
                    .join(session_id)
                    .join("tasks")
                    .join("task-1")
                    .join("checkpoints.jsonl");
                write_json_line(&checkpoint_path, &checkpoint);

                let signal_dir = context_root.join("agents/signals/codex/sess-merge");
                let signal = sample_signal("sig-acked", "merged timeline");
                write_signal_file(&signal_dir, &signal).expect("write acked signal");
                acknowledge_signal(
                    &signal_dir,
                    &SignalAck {
                        signal_id: "sig-acked".into(),
                        acknowledged_at: "2026-03-28T14:03:10Z".into(),
                        result: AckResult::Accepted,
                        agent: "codex".into(),
                        session_id: session_id.into(),
                        details: Some("loaded".into()),
                    },
                )
                .expect("ack signal");

                let observer_path =
                    context_root.join("agents/observe/observe-sess-merge/snapshot.json");
                write_json(&observer_path, &observer_state(session_id));

                let entries = session_timeline(session_id).expect("timeline");
                assert_eq!(entries.len(), 5);
                assert_eq!(entries[0].kind, "task_checkpoint");
                assert_eq!(
                    entries[0].summary,
                    "Checkpoint 70%: timeline rows are live-backed"
                );
                assert_eq!(entries[1].kind, "observe_snapshot");
                assert_eq!(
                    entries[1].summary,
                    "Observe scan: 1 open, 1 active workers, 1 muted codes"
                );
                assert_eq!(entries[2].kind, "signal_acknowledged");
                assert_eq!(
                    entries[2].summary,
                    "sig-acked acknowledged by codex-worker: Accepted (inject_context)"
                );
                assert_eq!(entries[3].kind, "signal_sent");
                assert_eq!(entries[4].kind, "task_created");
            },
        );
    }
}
