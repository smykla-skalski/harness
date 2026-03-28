use serde_json::to_value;

use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{SessionTransition, TaskCheckpoint};

use super::index;
use super::protocol::TimelineEntry;

/// Build a merged session timeline from session transitions and task checkpoints.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn session_timeline(session_id: &str) -> Result<Vec<TimelineEntry>, CliError> {
    let resolved = index::resolve_session(session_id)?;
    let mut entries = Vec::new();

    for log_entry in index::load_log_entries(&resolved.project, session_id)? {
        let (kind, task_id, summary) = transition_summary(&log_entry.transition);
        let payload = to_value(&log_entry.transition).map_err(|error| {
            CliError::from(CliErrorKind::workflow_serialize(format!(
                "serialize session transition for timeline: {error}"
            )))
        })?;
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

    entries.sort_by(|left, right| right.recorded_at.cmp(&left.recorded_at));
    Ok(entries)
}

fn checkpoint_entry(
    session_id: &str,
    checkpoint: &TaskCheckpoint,
) -> Result<TimelineEntry, CliError> {
    let payload = to_value(checkpoint).map_err(|error| {
        CliError::from(CliErrorKind::workflow_serialize(format!(
            "serialize task checkpoint for timeline: {error}"
        )))
    })?;
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
        } => (
            "agent_joined",
            None,
            format!("{agent_id} joined as {role:?} ({runtime})"),
        ),
        SessionTransition::AgentRemoved { agent_id } => {
            ("agent_removed", None, format!("{agent_id} removed"))
        }
        SessionTransition::RoleChanged { agent_id, from, to } => (
            "role_changed",
            None,
            format!("{agent_id}: {from:?} -> {to:?}"),
        ),
        SessionTransition::LeaderTransferRequested { from, to } => (
            "leader_transfer_requested",
            None,
            format!("Leadership transfer requested: {from} -> {to}"),
        ),
        SessionTransition::LeaderTransferred { from, to } => (
            "leader_transferred",
            None,
            format!("Leadership transferred: {from} -> {to}"),
        ),
        SessionTransition::TaskCreated {
            task_id,
            title,
            severity,
        } => (
            "task_created",
            Some(task_id.clone()),
            format!("{task_id} created [{severity:?}]: {title}"),
        ),
        SessionTransition::ObserveTaskCreated {
            task_id,
            title,
            severity,
            issue_id,
        } => (
            "observe_task_created",
            Some(task_id.clone()),
            format!(
                "{task_id} created from observe [{severity:?}]: {title}{}",
                issue_id
                    .as_deref()
                    .map_or_else(String::new, |id| format!(" ({id})"))
            ),
        ),
        SessionTransition::TaskAssigned { task_id, agent_id } => (
            "task_assigned",
            Some(task_id.clone()),
            format!("{task_id} assigned to {agent_id}"),
        ),
        SessionTransition::TaskStatusChanged { task_id, from, to } => (
            "task_status_changed",
            Some(task_id.clone()),
            format!("{task_id}: {from:?} -> {to:?}"),
        ),
        SessionTransition::TaskCheckpointRecorded {
            task_id,
            checkpoint_id,
            progress,
        } => (
            "task_checkpoint_recorded",
            Some(task_id.clone()),
            format!("{task_id} checkpoint {checkpoint_id} at {progress}%"),
        ),
        SessionTransition::SignalSent {
            signal_id,
            agent_id,
            command,
        } => (
            "signal_sent",
            None,
            format!("{signal_id} sent to {agent_id}: {command}"),
        ),
        SessionTransition::SignalAcknowledged {
            signal_id,
            agent_id,
            result,
        } => (
            "signal_acknowledged",
            None,
            format!("{signal_id} acknowledged by {agent_id}: {result:?}"),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    use fs_err as fs;
    use tempfile::tempdir;

    use crate::session::types::{
        CURRENT_VERSION, SessionMetrics, SessionState, SessionStatus, TaskSeverity, TaskStatus,
        WorkItem,
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
        fs::write(
            path,
            format!("{}\n", serde_json::to_string(value).expect("serialize")),
        )
        .expect("write");
    }

    fn sample_state(session_id: &str) -> SessionState {
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
            agents: BTreeMap::new(),
            tasks,
            leader_id: Some("leader-claude".into()),
            archived_at: None,
            last_activity_at: Some("2026-03-28T14:05:00Z".into()),
            observe_id: None,
            metrics: SessionMetrics::default(),
        }
    }

    #[test]
    fn session_timeline_merges_log_and_checkpoint_entries() {
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

                let entries = session_timeline(session_id).expect("timeline");
                assert_eq!(entries.len(), 2);
                assert_eq!(entries[0].kind, "task_checkpoint");
                assert_eq!(
                    entries[0].summary,
                    "Checkpoint 70%: timeline rows are live-backed"
                );
                assert_eq!(entries[1].kind, "task_created");
            },
        );
    }
}
