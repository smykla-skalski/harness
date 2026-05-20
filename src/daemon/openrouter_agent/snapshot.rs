//! Wire types for the `OpenRouter` managed-agent snapshots.

use serde::{Deserialize, Serialize};

use crate::daemon::agent_acp::permission_bridge::AcpPermissionBatch;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OpenRouterRunStatus {
    /// Initial state — session created but the first turn hasn't started.
    Pending,
    /// A turn is actively streaming from `OpenRouter`.
    Streaming,
    /// The latest turn finished cleanly and is awaiting more input.
    Idle,
    /// The latest turn was cancelled by the client.
    Cancelled,
    /// The latest turn failed (rate limit, auth, transport, …); `error` on
    /// the snapshot carries the human-readable cause.
    Failed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenRouterRunSnapshot {
    pub run_id: String,
    pub session_id: String,
    pub session_agent_id: Option<String>,
    pub display_name: String,
    pub model: String,
    pub status: OpenRouterRunStatus,
    /// Most recent assistant message (rolling, replaces on each turn). Set as
    /// chunks stream in; the final value is the assistant's completed text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_message: Option<String>,
    /// Reasoning trace text, when the model emits one (e.g. Claude thinking,
    /// o-series reasoning). Mirrors how chunks stream in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_reasoning: Option<String>,
    /// Final assistant message of the most-recently-completed turn. Persists
    /// after a turn ends so the consumer can read it after streaming stops.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub final_message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub turn_count: u32,
    /// Pending `DaemonBridge` permission batches the tool dispatcher is
    /// waiting on. Empty when no tool call needs user approval.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pending_permission_batches: Vec<AcpPermissionBatch>,
    pub created_at: String,
    pub updated_at: String,
}
