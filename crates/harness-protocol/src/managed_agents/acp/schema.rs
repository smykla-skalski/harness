//! `utoipa` schema mirrors for the ACP wire types that hand-roll their
//! `Serialize`/`Deserialize`. A plain `#[derive(ToSchema)]` on the public types
//! documents their Rust field layout, not the JSON they emit: the identity
//! fields are renamed on the wire (`acp_id` becomes `managed_agent_id`,
//! `agent_id` becomes `session_agent_id`) and a `managed_agent_family` tag is
//! injected that has no struct field at all. These mirrors reproduce the real
//! serialized shape and are referenced from the documented types via
//! `#[schema(value_type = ...)]` and from the handlers via `request_body = ...`.

use serde::{Deserialize, Serialize};

use super::mcp::AcpMcpServer;
use super::models::{AcpAgentHandshake, AcpAgentSessionState, AcpEndpoint, AcpPermissionItem};
use crate::session::{AgentStatusSchema, ManagedAgentKind, SessionRole};

/// Wire shape of the ACP agent start request. The descriptor is named
/// `descriptor_id` on the wire, not `agent`.
#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct AcpAgentStartRequestSchema {
    pub descriptor_id: String,
    pub role: SessionRole,
    #[serde(default)]
    pub fallback_role: Option<SessionRole>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub prompt: Option<String>,
    #[serde(default)]
    pub project_dir: Option<String>,
    #[serde(default)]
    pub persona: Option<String>,
    #[serde(default)]
    pub task_id: Option<String>,
    #[serde(default)]
    pub board_item_id: Option<String>,
    #[serde(default)]
    pub workflow_execution_id: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub allow_custom_model: bool,
    #[serde(default)]
    pub record_permissions: bool,
    #[serde(default)]
    pub mcp_servers: Vec<AcpMcpServer>,
    #[serde(default)]
    pub additional_directories: Vec<String>,
    #[serde(default)]
    pub resume_session_id: Option<String>,
    #[serde(default)]
    pub resume_disabled: bool,
    #[serde(default)]
    pub endpoint: Option<AcpEndpoint>,
}

/// Wire shape of a live ACP managed-agent snapshot.
#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct AcpAgentSnapshotSchema {
    pub managed_agent_id: String,
    pub managed_agent_family: ManagedAgentKind,
    pub session_id: String,
    pub session_agent_id: String,
    pub display_name: String,
    pub status: AgentStatusSchema,
    pub pid: u32,
    pub pgid: i32,
    pub project_dir: String,
    pub process_key: String,
    pub pending_permissions: usize,
    pub permission_queue_depth: usize,
    pub pending_permission_batches: Vec<AcpPermissionBatchSchema>,
    #[serde(default)]
    pub permission_mode: String,
    #[serde(default)]
    pub permission_log_path: Option<String>,
    pub terminal_count: usize,
    pub created_at: String,
    pub updated_at: String,
}

/// Wire shape of a pending ACP permission batch.
#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct AcpPermissionBatchSchema {
    pub batch_id: String,
    pub managed_agent_id: String,
    pub managed_agent_family: ManagedAgentKind,
    pub session_id: String,
    pub requests: Vec<AcpPermissionItem>,
    pub created_at: String,
    pub expires_at: String,
}

/// Wire shape of the ACP inspect snapshot.
#[derive(Serialize, Deserialize, utoipa::ToSchema)]
pub struct AcpAgentInspectSnapshotSchema {
    pub managed_agent_id: String,
    pub managed_agent_family: ManagedAgentKind,
    pub session_id: String,
    pub session_agent_id: String,
    pub display_name: String,
    pub pid: u32,
    pub pgid: i32,
    #[serde(default)]
    pub process_key: String,
    pub uptime_ms: u64,
    pub last_update_at: String,
    #[serde(default)]
    pub last_client_call_at: Option<String>,
    pub watchdog_state: String,
    #[serde(default)]
    pub permission_mode: String,
    #[serde(default)]
    pub permission_log_path: Option<String>,
    pub pending_permissions: usize,
    #[serde(default)]
    pub permission_queue_depth: usize,
    pub terminal_count: usize,
    pub prompt_deadline_remaining_ms: u64,
    #[serde(default)]
    pub handshake: Option<AcpAgentHandshake>,
    #[serde(default)]
    pub session_state: Option<AcpAgentSessionState>,
}
