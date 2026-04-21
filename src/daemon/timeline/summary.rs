use crate::agents::runtime::signal::AckResult;
use crate::session::types::{SessionRole, SessionTransition, TaskSeverity, TaskStatus};

pub(super) fn transition_summary(
    transition: &SessionTransition,
) -> (&'static str, Option<String>, String) {
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
        SessionTransition::SessionAdopted { session_id } => (
            "session_adopted",
            None,
            format!("Session adopted: {session_id}"),
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

pub(super) fn signal_ack_summary(
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
