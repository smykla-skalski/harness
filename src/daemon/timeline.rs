use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::agents::runtime::signal::{
    AckResult, Signal, SignalAck, read_acknowledged_signals, read_acknowledgments,
};
use crate::agents::runtime::signal_session_keys;
use serde_json::to_value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::observe::types::ObserverState;
use crate::session::types::{
    SessionLogEntry, SessionRole, SessionState, SessionTransition, TaskCheckpoint, TaskSeverity,
    TaskStatus,
};

use super::index;
use super::protocol::TimelineEntry;

/// Build a merged session timeline from session transitions and task checkpoints.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn session_timeline(session_id: &str) -> Result<Vec<TimelineEntry>, CliError> {
    let resolved = index::resolve_session(session_id)?;
    session_timeline_from_resolved(&resolved)
}

/// Build a timeline from a pre-resolved session (avoids full discovery).
///
/// # Errors
/// Returns [`CliError`] on parse failures.
pub fn session_timeline_from_resolved(
    resolved: &index::ResolvedSession,
) -> Result<Vec<TimelineEntry>, CliError> {
    build_timeline(resolved, None)
}

/// Build timeline using the DB for log entries and checkpoints when available.
///
/// # Errors
/// Returns [`CliError`] on parse failures.
pub fn session_timeline_from_resolved_with_db(
    resolved: &index::ResolvedSession,
    db: &super::db::DaemonDb,
) -> Result<Vec<TimelineEntry>, CliError> {
    build_timeline(resolved, Some(db))
}

fn build_timeline(
    resolved: &index::ResolvedSession,
    db: Option<&super::db::DaemonDb>,
) -> Result<Vec<TimelineEntry>, CliError> {
    let session_id = &resolved.state.session_id;
    let mut entries = Vec::new();
    let mut logged_signal_acks = HashSet::new();
    let mut sent_signals = BTreeMap::new();

    let log_entries = load_log_entries_hybrid(db, &resolved.project, session_id)?;
    for log_entry in log_entries {
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

    entries.extend(load_conversation_entries_hybrid(
        db,
        &resolved.project,
        &resolved.state,
    )?);

    for task_id in resolved.state.tasks.keys() {
        let checkpoints = load_checkpoints_hybrid(db, &resolved.project, session_id, task_id)?;
        for checkpoint in checkpoints {
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

fn load_log_entries_hybrid(
    db: Option<&super::db::DaemonDb>,
    project: &index::DiscoveredProject,
    session_id: &str,
) -> Result<Vec<SessionLogEntry>, CliError> {
    if let Some(db) = db {
        return db.load_session_log(session_id);
    }
    index::load_log_entries(project, session_id)
}

fn load_checkpoints_hybrid(
    db: Option<&super::db::DaemonDb>,
    project: &index::DiscoveredProject,
    session_id: &str,
    task_id: &str,
) -> Result<Vec<TaskCheckpoint>, CliError> {
    if let Some(db) = db {
        return db.load_task_checkpoints(session_id, task_id);
    }
    index::load_task_checkpoints(project, session_id, task_id)
}

fn load_conversation_entries_hybrid(
    db: Option<&super::db::DaemonDb>,
    project: &index::DiscoveredProject,
    state: &SessionState,
) -> Result<Vec<TimelineEntry>, CliError> {
    if let Some(db) = db {
        return conversation_entries_from_db(db, state);
    }
    conversation_entries(project, state)
}

fn conversation_entries_from_db(
    db: &super::db::DaemonDb,
    state: &SessionState,
) -> Result<Vec<TimelineEntry>, CliError> {
    let mut entries = Vec::new();
    for (agent_id, agent) in &state.agents {
        let events = db.load_conversation_events(&state.session_id, agent_id)?;
        for event in events {
            if let Some(entry) =
                conversation_entry(&state.session_id, agent_id, &agent.runtime, &event)?
            {
                entries.push(entry);
            }
        }
    }
    Ok(entries)
}

fn conversation_entries(
    project: &index::DiscoveredProject,
    state: &SessionState,
) -> Result<Vec<TimelineEntry>, CliError> {
    let mut entries = Vec::new();
    for (agent_id, agent) in &state.agents {
        let session_key = agent
            .agent_session_id
            .as_deref()
            .unwrap_or(&state.session_id);
        let events =
            index::load_conversation_events(project, &agent.runtime, session_key, agent_id)?;
        for event in events {
            if let Some(entry) =
                conversation_entry(&state.session_id, agent_id, &agent.runtime, &event)?
            {
                entries.push(entry);
            }
        }
    }
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

fn conversation_entry(
    session_id: &str,
    agent_id: &str,
    runtime: &str,
    event: &ConversationEvent,
) -> Result<Option<TimelineEntry>, CliError> {
    let Some(recorded_at) = event.timestamp.clone() else {
        return Ok(None);
    };

    let (entry_kind, summary) = match &event.kind {
        ConversationEventKind::ToolInvocation { tool_name, .. } => {
            ("tool_invocation", format!("{agent_id} invoked {tool_name}"))
        }
        ConversationEventKind::ToolResult {
            tool_name,
            is_error,
            ..
        } => {
            let kind = if *is_error {
                "tool_result_error"
            } else {
                "tool_result"
            };
            let summary = if *is_error {
                format!("{agent_id} received an error from {tool_name}")
            } else {
                format!("{agent_id} received a result from {tool_name}")
            };
            (kind, summary)
        }
        ConversationEventKind::Error { message, .. } => {
            ("agent_error", format!("{agent_id} error: {message}"))
        }
        ConversationEventKind::SignalReceived { signal_id, command } => (
            "signal_received",
            format!("{agent_id} picked up {signal_id} ({command})"),
        ),
        ConversationEventKind::StateChange { from, to } => (
            "agent_state_change",
            format!("{agent_id} state changed {from} -> {to}"),
        ),
        ConversationEventKind::FileModification { path, operation } => (
            "file_modification",
            format!("{agent_id} {operation} {}", path.display()),
        ),
        ConversationEventKind::SessionMarker { marker } => (
            "agent_session_marker",
            format!("{agent_id} marked {marker}"),
        ),
        ConversationEventKind::UserPrompt { .. }
        | ConversationEventKind::AssistantText { .. }
        | ConversationEventKind::Other { .. } => return Ok(None),
    };
    let payload = timeline_payload(
        &serde_json::json!({
            "runtime": runtime,
            "event": event.kind,
        }),
        "agent conversation event",
    )?;

    Ok(Some(TimelineEntry {
        entry_id: format!("{runtime}-{agent_id}-{entry_kind}-{}", event.sequence),
        recorded_at,
        kind: entry_kind.into(),
        session_id: session_id.to_string(),
        agent_id: Some(agent_id.to_string()),
        task_id: None,
        summary,
        payload,
    }))
}

fn signal_ack_entries(
    state: &SessionState,
    context_root: &Path,
    sent_signals: &BTreeMap<String, LoggedSignal>,
    logged_signal_acks: &HashSet<String>,
) -> Result<Vec<TimelineEntry>, CliError> {
    let mut entries = Vec::new();
    let signals_root = index::signals_root(context_root);
    let mut acknowledgments_by_id = BTreeMap::new();
    let mut signals_by_id = BTreeMap::new();

    for agent in state.agents.values() {
        for signal_session_id in
            signal_session_keys(&state.session_id, agent.agent_session_id.as_deref())
        {
            let signal_dir = signals_root.join(&agent.runtime).join(signal_session_id);
            for acknowledgment in read_acknowledgments(&signal_dir)? {
                acknowledgments_by_id
                    .entry(acknowledgment.signal_id.clone())
                    .or_insert((agent.runtime.clone(), acknowledgment));
            }
            for signal in read_acknowledged_signals(&signal_dir)? {
                signals_by_id
                    .entry(signal.signal_id.clone())
                    .or_insert(signal);
            }
        }
    }

    for (signal_id, (runtime, acknowledgment)) in acknowledgments_by_id {
        if logged_signal_acks.contains(&signal_id) {
            continue;
        }
        let signal = signals_by_id.get(&signal_id);
        let logged_signal = sent_signals.get(&signal_id);
        entries.push(signal_ack_entry(
            &state.session_id,
            &runtime,
            logged_signal,
            signal,
            &acknowledgment,
        )?);
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
    let summary = signal_ack_summary(
        &acknowledgment.signal_id,
        agent_id,
        acknowledgment.result,
        command,
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
        SessionTransition::SessionStarted { title, context } => (
            "session_started",
            None,
            if title.is_empty() {
                format!("Session started: {context}")
            } else {
                format!("Session started: {title} - {context}")
            },
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
        SessionTransition::TaskQueued { task_id, agent_id } => {
            task_queued_summary(task_id, agent_id)
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
        SessionTransition::AgentDisconnected { agent_id, reason } => (
            "agent_disconnected",
            None,
            format!("{agent_id} disconnected: {reason}"),
        ),
        SessionTransition::AgentLeft { agent_id } => {
            ("agent_left", None, format!("{agent_id} left the session"))
        }
        SessionTransition::LivenessSynced {
            disconnected,
            idled,
        } => (
            "liveness_synced",
            None,
            format!(
                "Liveness sync: {} disconnected, {} idled",
                disconnected.len(),
                idled.len()
            ),
        ),
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

fn task_queued_summary(task_id: &str, agent_id: &str) -> (&'static str, Option<String>, String) {
    (
        "task_queued",
        Some(task_id.to_string()),
        format!("{task_id} queued for {agent_id}"),
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
        signal_ack_summary(signal_id, agent_id, result, None),
    )
}

fn signal_ack_summary(
    signal_id: &str,
    agent_id: &str,
    result: AckResult,
    command: Option<&str>,
) -> String {
    match command {
        Some(command) => format!(
            "{signal_id} {} {agent_id}: {result:?} ({command})",
            signal_ack_verb(result)
        ),
        None => format!(
            "{signal_id} {} {agent_id}: {result:?}",
            signal_ack_verb(result)
        ),
    }
}

fn signal_ack_verb(result: AckResult) -> &'static str {
    match result {
        AckResult::Accepted => "delivered to",
        AckResult::Rejected | AckResult::Deferred | AckResult::Expired => "acknowledged by",
    }
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
        SessionStatus, TaskQueuePolicy, TaskSeverity, TaskStatus, WorkItem,
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
                current_task_id: Some("task-1".into()),
                runtime_capabilities: RuntimeCapabilities::default(),
                persona: None,
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
                queue_policy: TaskQueuePolicy::Locked,
                queued_at: None,
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
            title: "test session".into(),
            context: "test goal".into(),
            status: SessionStatus::Active,
            created_at: "2026-03-28T14:00:00Z".into(),
            updated_at: "2026-03-28T14:05:00Z".into(),
            agents,
            tasks,
            leader_id: Some(format!("{runtime}-worker")),
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

                let transcript_path = context_root
                    .join("agents")
                    .join("sessions")
                    .join("codex")
                    .join("codex-session-1")
                    .join("raw.jsonl");
                write_json_line(
                    &transcript_path,
                    &serde_json::json!({
                        "timestamp": "2026-03-28T14:05:30Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_use",
                                "name": "Read",
                                "input": {"path": "src/daemon/timeline.rs"},
                                "id": "call-read-1"
                            }]
                        }
                    }),
                );
                write_json_line(
                    &transcript_path,
                    &serde_json::json!({
                        "timestamp": "2026-03-28T14:05:45Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_result",
                                "tool_name": "Read",
                                "tool_use_id": "call-read-1",
                                "content": {"line_count": 48},
                                "is_error": false
                            }]
                        }
                    }),
                );

                let entries = session_timeline(session_id).expect("timeline");
                assert_eq!(entries.len(), 7);
                assert_eq!(entries[0].kind, "task_checkpoint");
                assert_eq!(
                    entries[0].summary,
                    "Checkpoint 70%: timeline rows are live-backed"
                );
                assert_eq!(entries[1].kind, "tool_result");
                assert_eq!(
                    entries[1].summary,
                    "codex-worker received a result from Read"
                );
                assert_eq!(entries[2].kind, "tool_invocation");
                assert_eq!(entries[2].summary, "codex-worker invoked Read");
                assert_eq!(entries[3].kind, "observe_snapshot");
                assert_eq!(
                    entries[3].summary,
                    "Observe scan: 1 open, 1 active workers, 1 muted codes"
                );
                assert_eq!(entries[4].kind, "signal_acknowledged");
                assert_eq!(
                    entries[4].summary,
                    "sig-acked delivered to codex-worker: Accepted (inject_context)"
                );
                assert_eq!(entries[5].kind, "signal_sent");
                assert_eq!(entries[6].kind, "task_created");
            },
        );
    }

    #[test]
    fn session_timeline_uses_ledger_fallback_for_copilot_tool_events() {
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
                        "hook": "tool-guard",
                        "decision": "allow",
                        "payload": {
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
                        }
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
                        "hook": "tool-result",
                        "decision": "allow",
                        "payload": {
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
                        }
                    }),
                );

                let entries = session_timeline(session_id).expect("timeline");
                assert_eq!(entries.len(), 2);
                assert_eq!(entries[0].kind, "tool_result");
                assert_eq!(
                    entries[0].summary,
                    "copilot-worker received a result from Read"
                );
                assert_eq!(entries[1].kind, "tool_invocation");
                assert_eq!(entries[1].summary, "copilot-worker invoked Read");
            },
        );
    }
}
