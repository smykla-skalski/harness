use serde::{Deserialize, Serialize};

use crate::agents::runtime::signal::AckResult;
use crate::session::types::{SessionRole, SessionState, TaskQueuePolicy, TaskSeverity, TaskStatus};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoleChangeRequest {
    pub actor: String,
    pub role: SessionRole,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRemoveRequest {
    pub actor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LeaderTransferRequest {
    pub actor: String,
    pub new_leader_id: String,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCreateRequest {
    pub actor: String,
    pub title: String,
    pub context: Option<String>,
    pub severity: TaskSeverity,
    pub suggested_fix: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskAssignRequest {
    pub actor: String,
    pub agent_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskDropRequest {
    pub actor: String,
    pub target: TaskDropTarget,
    #[serde(default)]
    pub queue_policy: TaskQueuePolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "target_type", rename_all = "snake_case")]
pub enum TaskDropTarget {
    Agent { agent_id: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskQueuePolicyRequest {
    pub actor: String,
    pub queue_policy: TaskQueuePolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskUpdateRequest {
    pub actor: String,
    pub status: TaskStatus,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCheckpointRequest {
    pub actor: String,
    pub summary: String,
    pub progress: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEndRequest {
    pub actor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionLeaveRequest {
    pub agent_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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
pub struct ObserveSessionRequest {
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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
pub struct SessionMutationResponse {
    pub state: SessionState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdoptSessionRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookmark_id: Option<String>,
    pub session_root: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRuntimeSessionRegistrationRequest {
    pub tui_id: String,
    pub runtime: String,
    pub agent_session_id: String,
    pub project_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRuntimeSessionRegistrationResponse {
    pub registered: bool,
}
