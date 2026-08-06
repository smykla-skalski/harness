use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceLivenessStatus, AgentWorkspaceMembershipStatus, AgentWorkspaceRuntimeLifecycle,
};

pub(super) const fn membership_label(value: AgentWorkspaceMembershipStatus) -> &'static str {
    match value {
        AgentWorkspaceMembershipStatus::PendingRegistration => "pending_registration",
        AgentWorkspaceMembershipStatus::Joined => "joined",
        AgentWorkspaceMembershipStatus::Removed => "removed",
        AgentWorkspaceMembershipStatus::Historical => "historical",
    }
}

pub(super) const fn liveness_label(value: AgentWorkspaceLivenessStatus) -> &'static str {
    match value {
        AgentWorkspaceLivenessStatus::Active => "active",
        AgentWorkspaceLivenessStatus::Idle => "idle",
        AgentWorkspaceLivenessStatus::AwaitingReview => "awaiting_review",
        AgentWorkspaceLivenessStatus::Disconnected => "disconnected",
        AgentWorkspaceLivenessStatus::Removed => "removed",
        AgentWorkspaceLivenessStatus::Unknown => "unknown",
    }
}

pub(super) const fn runtime_lifecycle_label(value: AgentWorkspaceRuntimeLifecycle) -> &'static str {
    match value {
        AgentWorkspaceRuntimeLifecycle::Running => "running",
        AgentWorkspaceRuntimeLifecycle::Recoverable => "recoverable",
        AgentWorkspaceRuntimeLifecycle::Completed => "completed",
        AgentWorkspaceRuntimeLifecycle::Failed => "failed",
        AgentWorkspaceRuntimeLifecycle::Unavailable => "unavailable",
    }
}

pub(super) fn parse_membership(value: &str) -> Result<AgentWorkspaceMembershipStatus, CliError> {
    match value {
        "pending_registration" => Ok(AgentWorkspaceMembershipStatus::PendingRegistration),
        "joined" => Ok(AgentWorkspaceMembershipStatus::Joined),
        "removed" => Ok(AgentWorkspaceMembershipStatus::Removed),
        "historical" => Ok(AgentWorkspaceMembershipStatus::Historical),
        _ => Err(db_error(format!("unknown agent team membership '{value}'"))),
    }
}

pub(super) fn parse_liveness(value: &str) -> Result<AgentWorkspaceLivenessStatus, CliError> {
    match value {
        "active" => Ok(AgentWorkspaceLivenessStatus::Active),
        "idle" => Ok(AgentWorkspaceLivenessStatus::Idle),
        "awaiting_review" => Ok(AgentWorkspaceLivenessStatus::AwaitingReview),
        "disconnected" => Ok(AgentWorkspaceLivenessStatus::Disconnected),
        "removed" => Ok(AgentWorkspaceLivenessStatus::Removed),
        "unknown" => Ok(AgentWorkspaceLivenessStatus::Unknown),
        _ => Err(db_error(format!("unknown agent team liveness '{value}'"))),
    }
}

pub(super) fn parse_runtime_lifecycle(
    value: &str,
) -> Result<AgentWorkspaceRuntimeLifecycle, CliError> {
    match value {
        "running" => Ok(AgentWorkspaceRuntimeLifecycle::Running),
        "recoverable" => Ok(AgentWorkspaceRuntimeLifecycle::Recoverable),
        "completed" => Ok(AgentWorkspaceRuntimeLifecycle::Completed),
        "failed" => Ok(AgentWorkspaceRuntimeLifecycle::Failed),
        "unavailable" => Ok(AgentWorkspaceRuntimeLifecycle::Unavailable),
        _ => Err(db_error(format!(
            "unknown agent team runtime lifecycle '{value}'"
        ))),
    }
}
