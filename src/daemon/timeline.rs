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
