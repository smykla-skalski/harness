use clap::ValueEnum;
use serde::{Deserialize, Serialize};

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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resume_thread_id: Option<String>,
    /// Optional model identifier validated against the codex catalog. `None`
    /// means use the runtime default selected by the codex app-server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Optional reasoning effort level (e.g. `low`, `medium`, `high`,
    /// `xhigh`). Forwarded to the codex app-server as `reasoning_effort` and
    /// ignored when the selected model does not support reasoning.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// When `true`, the `model` field is accepted as-is without catalog
    /// validation and any effort value is forwarded without checking the
    /// model's `effort_values`.
    #[serde(default, skip_serializing_if = "core::ops::Not::not")]
    pub allow_custom_model: bool,
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
pub struct CodexRunSnapshot {
    pub run_id: String,
    pub session_id: String,
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
    pub created_at: String,
    pub updated_at: String,
    /// Optional model identifier passed to the codex app-server at thread
    /// start. Not persisted yet; reloads from the database always populate
    /// this with `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Optional reasoning effort forwarded to the codex app-server at thread
    /// start. Tracked on the in-memory snapshot only, matching `model`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexApprovalRequestedPayload {
    pub run: CodexRunSnapshot,
    pub approval: CodexApprovalRequest,
}
