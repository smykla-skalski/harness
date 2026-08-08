use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent::{AckResult, ConversationEvent, Signal, SignalAck};
use crate::session::SessionSignalStatus;
use crate::timeline::TimelineCursor;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AgentWorkspaceActivityOwnerKind {
    Workspace,
    ManagedAgent,
    WorkItem,
    Review,
    Execution,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceActivityOwner {
    pub kind: AgentWorkspaceActivityOwnerKind,
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceActivityEntry {
    pub entry_id: String,
    pub recorded_at: String,
    pub kind: String,
    pub owner: AgentWorkspaceActivityOwner,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub member_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_task_id: Option<String>,
    pub summary: String,
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceActivityWindowResponse {
    pub workspace_id: String,
    pub revision: i64,
    pub total_count: usize,
    pub window_start: usize,
    pub window_end: usize,
    pub has_older: bool,
    pub has_newer: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oldest_cursor: Option<TimelineCursor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub newest_cursor: Option<TimelineCursor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entries: Option<Vec<AgentWorkspaceActivityEntry>>,
    pub unchanged: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceSignalRecord {
    pub workspace_id: String,
    pub member_id: String,
    pub owner: AgentWorkspaceActivityOwner,
    pub runtime: String,
    pub status: SessionSignalStatus,
    pub signal: Signal,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acknowledgment: Option<SignalAck>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_agent_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceConversationRecord {
    pub workspace_id: String,
    pub member_id: String,
    pub owner: AgentWorkspaceActivityOwner,
    pub runtime: String,
    pub recorded_at: String,
    #[schema(value_type = Object)]
    pub event: ConversationEvent,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_agent_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceMemberActivityResponse {
    pub workspace_id: String,
    pub member_id: String,
    pub owner: AgentWorkspaceActivityOwner,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity: Option<Value>,
    #[serde(default)]
    pub conversation: Vec<AgentWorkspaceConversationRecord>,
    #[serde(default)]
    pub signals: Vec<AgentWorkspaceSignalRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceSignalSendRequest {
    pub actor: String,
    pub idempotency_key: String,
    pub command: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceSignalAckRequest {
    pub result: AckResult,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentWorkspaceSignalCancelRequest {
    pub actor: String,
}
