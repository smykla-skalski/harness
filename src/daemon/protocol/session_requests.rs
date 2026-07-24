use serde::{Deserialize, Serialize};

use crate::agents::runtime::signal::AckResult;
use crate::session::service::ImproverTarget;
use crate::session::types::{
    ReviewPoint, ReviewVerdict, SessionRole, SessionState, TaskQueuePolicy, TaskSeverity,
    TaskStatus,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct RoleChangeRequest {
    pub actor: String,
    pub role: SessionRole,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct AgentRemoveRequest {
    pub actor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct LeaderTransferRequest {
    pub actor: String,
    pub new_leader_id: String,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskCreateRequest {
    pub actor: String,
    pub title: String,
    pub context: Option<String>,
    pub severity: TaskSeverity,
    pub suggested_fix: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskDeleteRequest {
    pub actor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskAssignRequest {
    pub actor: String,
    pub agent_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskDropRequest {
    pub actor: String,
    pub target: TaskDropTarget,
    #[serde(default)]
    pub queue_policy: TaskQueuePolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
#[serde(tag = "target_type", rename_all = "snake_case")]
pub enum TaskDropTarget {
    Agent { agent_id: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskQueuePolicyRequest {
    pub actor: String,
    pub queue_policy: TaskQueuePolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskUpdateRequest {
    pub actor: String,
    pub status: TaskStatus,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskCheckpointRequest {
    pub actor: String,
    pub summary: String,
    // The daemon rejects progress above 100 (`ensure_valid_progress`); bound
    // the schema so a generated client sees the ceiling it must not exceed.
    #[cfg_attr(feature = "openapi", schema(maximum = 100))]
    pub progress: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SessionEndRequest {
    pub actor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SessionArchiveRequest {
    pub actor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SessionLeaveRequest {
    pub agent_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SessionTitleRequest {
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalSendRequest {
    pub actor: String,
    pub agent_id: String,
    pub command: String,
    pub message: String,
    pub action_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct ObserveSessionRequest {
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SessionStartRequest {
    #[serde(default)]
    pub title: String,
    pub context: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub project_dir: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_preset: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SessionJoinRequest {
    pub runtime: String,
    pub role: SessionRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_role: Option<SessionRole>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub project_dir: String,
    /// Persona identifier to resolve and attach to the agent registration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub persona: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalAckRequest {
    pub agent_id: String,
    pub signal_id: String,
    pub result: AckResult,
    pub project_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalCancelRequest {
    pub actor: String,
    pub agent_id: String,
    pub signal_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskSubmitForReviewRequest {
    pub actor: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggested_persona: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskClaimReviewRequest {
    pub actor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskSubmitReviewRequest {
    pub actor: String,
    pub verdict: ReviewVerdict,
    pub summary: String,
    #[serde(default)]
    pub points: Vec<ReviewPoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskRespondReviewRequest {
    pub actor: String,
    #[serde(default)]
    pub agreed: Vec<String>,
    #[serde(default)]
    pub disputed: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskArbitrateRequest {
    pub actor: String,
    pub verdict: ReviewVerdict,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct ImproverApplyRequest {
    pub actor: String,
    pub issue_id: String,
    pub target: ImproverTarget,
    pub rel_path: String,
    pub new_contents: String,
    pub project_dir: String,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SessionMutationResponse {
    pub state: SessionState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SessionArchiveResponse {
    pub session_id: String,
    pub archived_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct AdoptSessionRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookmark_id: Option<String>,
    pub session_root: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct AgentRuntimeSessionRegistrationRequest {
    pub managed_agent_id: String,
    pub runtime: String,
    pub runtime_session_id: String,
    pub project_dir: String,
}

#[cfg(test)]
mod tests {
    use super::AgentRuntimeSessionRegistrationRequest;

    #[test]
    fn agent_runtime_session_registration_request_serializes_runtime_session_id() {
        let request = AgentRuntimeSessionRegistrationRequest {
            managed_agent_id: "managed-agent-1".into(),
            runtime: "codex".into(),
            runtime_session_id: "runtime-1".into(),
            project_dir: "/tmp/project".into(),
        };

        let json = serde_json::to_value(&request).expect("serialize runtime session request");

        assert_eq!(json["managed_agent_id"], "managed-agent-1");
        assert_eq!(json["runtime_session_id"], "runtime-1");
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct AgentRuntimeSessionRegistrationResponse {
    pub registered: bool,
}
