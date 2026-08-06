use harness_protocol::agent::DisconnectReason;
use harness_protocol::daemon::summaries::AgentWorkspaceRuntimeLifecycle;
use harness_protocol::session::AgentStatus;

use super::identity::member_source_digest;
use super::source::{CodexRow, RegistrationRow, TuiRow};

pub(super) fn registration_digest(row: &RegistrationRow) -> String {
    member_source_digest(&[
        &row.session_id,
        &row.agent_id,
        &row.name,
        &row.runtime,
        &row.role,
        &row.capabilities_json,
        &row.status,
        row.runtime_session_id.as_deref().unwrap_or_default(),
        row.managed_agent_kind.as_deref().unwrap_or_default(),
        row.managed_agent_id.as_deref().unwrap_or_default(),
        &row.joined_at,
        &row.updated_at,
        row.last_activity_at.as_deref().unwrap_or_default(),
        row.current_task_id.as_deref().unwrap_or_default(),
        &row.runtime_capabilities_json,
    ])
}

pub(super) fn registration_operation_marker(row: &RegistrationRow) -> String {
    operation_source_marker(&[&row.status, &row.updated_at])
}

pub(super) fn registration_runtime_lifecycle(
    row: &RegistrationRow,
) -> AgentWorkspaceRuntimeLifecycle {
    if row.managed_agent_kind.as_deref() != Some("acp") {
        return AgentWorkspaceRuntimeLifecycle::Unavailable;
    }
    let Ok(status) = serde_json::from_str::<AgentStatus>(&row.status) else {
        return AgentWorkspaceRuntimeLifecycle::Unavailable;
    };
    match status {
        AgentStatus::Disconnected { reason, .. } if reason.is_restartable() => {
            AgentWorkspaceRuntimeLifecycle::Recoverable
        }
        AgentStatus::Disconnected {
            reason:
                DisconnectReason::UserCancelled
                | DisconnectReason::SessionStopped
                | DisconnectReason::SessionEnded,
            ..
        } => AgentWorkspaceRuntimeLifecycle::Completed,
        AgentStatus::Active
        | AgentStatus::Idle
        | AgentStatus::AwaitingReview
        | AgentStatus::Removed
        | AgentStatus::Disconnected { .. } => AgentWorkspaceRuntimeLifecycle::Unavailable,
    }
}

pub(super) fn registration_runtime_evidence(row: &RegistrationRow) -> String {
    runtime_evidence(
        &row.runtime,
        &row.status,
        row.runtime_session_id.as_deref(),
        None,
        None,
    )
}

pub(super) fn tui_digest(row: &TuiRow) -> String {
    member_source_digest(&[
        &row.tui_id,
        &row.session_id,
        &row.agent_id,
        &row.runtime,
        &row.status,
        &row.created_at,
        &row.updated_at,
    ])
}

pub(super) fn tui_operation_marker(row: &TuiRow) -> String {
    operation_source_marker(&[&row.tui_id, &row.status, &row.updated_at])
}

pub(super) fn codex_digest(row: &CodexRow) -> String {
    member_source_digest(&[
        &row.run_id,
        &row.session_id,
        row.session_agent_id.as_deref().unwrap_or_default(),
        row.display_name.as_deref().unwrap_or_default(),
        row.thread_id.as_deref().unwrap_or_default(),
        row.task_id.as_deref().unwrap_or_default(),
        &row.status,
        &row.created_at,
        &row.updated_at,
    ])
}

pub(super) fn codex_operation_marker(row: &CodexRow) -> String {
    operation_source_marker(&[&row.run_id, &row.status, &row.updated_at])
}

fn operation_source_marker(fields: &[&str]) -> String {
    hex::encode(fields.join("\0"))
}

pub(super) fn runtime_evidence(
    family: &str,
    status: &str,
    primary: Option<&str>,
    secondary: Option<&str>,
    error: Option<&str>,
) -> String {
    [
        format!("family={family}"),
        format!("status={status}"),
        format!("primary={}", primary.unwrap_or_default()),
        format!("secondary={}", secondary.unwrap_or_default()),
        format!("error={}", error.unwrap_or_default()),
    ]
    .join(";")
}
