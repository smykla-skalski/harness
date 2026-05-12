use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::session::types::SessionRole;

use super::summaries::TimelineEntry;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum CodexRunMode {
    Report,
    WorkspaceWrite,
    Approval,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexRunStatus {
    Queued,
    Running,
    WaitingApproval,
    Completed,
    Failed,
    Cancelled,
}

impl CodexRunStatus {
    #[must_use]
    pub const fn is_active(self) -> bool {
        matches!(self, Self::Queued | Self::Running | Self::WaitingApproval)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum CodexApprovalDecision {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRunRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    pub prompt: String,
    pub mode: CodexRunMode,
    #[serde(default = "default_codex_agent_role")]
    pub role: SessionRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_role: Option<SessionRole>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub persona: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resume_thread_id: Option<String>,
    /// Optional model identifier validated against the codex catalog. `None`
    /// means use the runtime default selected by the codex app-server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Optional reasoning effort level (e.g. `low`, `medium`, `high`,
    /// `xhigh`). Forwarded to the codex app-server `turn/start` payload as
    /// `effort` and ignored when the selected model does not support reasoning.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// When `true`, the `model` field is accepted as-is without catalog
    /// validation and any effort value is forwarded without checking the
    /// model's `effort_values`.
    #[serde(default, skip_serializing_if = "core::ops::Not::not")]
    pub allow_custom_model: bool,
}

fn default_codex_agent_role() -> SessionRole {
    SessionRole::Worker
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexSteerRequest {
    pub prompt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexApprovalDecisionRequest {
    pub decision: CodexApprovalDecision,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRunListResponse {
    pub runs: Vec<CodexRunSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexAgentInspectResponse {
    pub agents: Vec<CodexAgentInspectSnapshot>,
    pub daemon_perceived_now: String,
    pub available: bool,
    pub issue_message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexAgentInspectSnapshot {
    pub run_id: String,
    pub session_id: String,
    pub agent_id: Option<String>,
    pub display_name: String,
    pub status: CodexRunStatus,
    pub project_dir: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub active: bool,
    pub attached: bool,
    pub pending_approvals: usize,
    pub resolved_approvals: usize,
    pub event_count: usize,
    pub last_update_at: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub latest_summary: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexTranscriptResponse {
    pub entries: Vec<TimelineEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexApprovalRequest {
    pub approval_id: String,
    pub request_id: String,
    pub kind: String,
    pub title: String,
    pub detail: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub item_id: Option<String>,
    pub cwd: Option<String>,
    pub command: Option<String>,
    pub file_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexResolvedApproval {
    pub approval_id: String,
    pub decision: CodexApprovalDecision,
    pub resolved_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRunEvent {
    pub event_id: String,
    pub sequence: u64,
    pub recorded_at: String,
    pub kind: String,
    pub summary: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub item_id: Option<String>,
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRunSnapshot {
    pub run_id: String,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub project_dir: String,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub mode: CodexRunMode,
    pub status: CodexRunStatus,
    pub prompt: String,
    pub latest_summary: Option<String>,
    pub final_message: Option<String>,
    pub error: Option<String>,
    pub pending_approvals: Vec<CodexApprovalRequest>,
    #[serde(default)]
    pub resolved_approvals: Vec<CodexResolvedApproval>,
    #[serde(default)]
    pub events: Vec<CodexRunEvent>,
    pub created_at: String,
    pub updated_at: String,
    /// Optional model identifier passed to the codex app-server for the thread
    /// and turn context.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Optional reasoning effort forwarded to the codex app-server turn context.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexApprovalRequestedPayload {
    pub run: CodexRunSnapshot,
    pub approval: CodexApprovalRequest,
}
