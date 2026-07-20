use std::collections::BTreeSet;
use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::super::runtime_models::RuntimeModelCatalog;
use super::mcp::{AcpMcpServer, serialize_mcp_servers_redacted};
use crate::session::{AgentStatus, SessionRole};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpAgentStartRequest {
    pub agent: String,
    pub role: SessionRole,
    pub fallback_role: Option<SessionRole>,
    pub capabilities: Vec<String>,
    pub name: Option<String>,
    pub prompt: Option<String>,
    pub project_dir: Option<String>,
    pub persona: Option<String>,
    pub task_id: Option<String>,
    pub board_item_id: Option<String>,
    pub workflow_execution_id: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub allow_custom_model: bool,
    pub record_permissions: bool,
    /// Added to the descriptor's own servers; same name overrides.
    pub mcp_servers: Vec<AcpMcpServer>,
    /// Added to the descriptor's own roots.
    pub additional_directories: Vec<String>,
}

impl Default for AcpAgentStartRequest {
    fn default() -> Self {
        Self {
            agent: String::new(),
            role: default_acp_role(),
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            prompt: None,
            project_dir: None,
            persona: None,
            task_id: None,
            board_item_id: None,
            workflow_execution_id: None,
            model: None,
            effort: None,
            allow_custom_model: false,
            record_permissions: false,
            mcp_servers: Vec::new(),
            additional_directories: Vec::new(),
        }
    }
}

pub type CapabilityTag = String;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DoctorProbe {
    pub command: String,
    pub args: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AcpSpawnConfiguration {
    #[default]
    DescriptorRuntime,
    Runtime {
        name: String,
    },
    None,
}

impl AcpSpawnConfiguration {
    #[must_use]
    pub fn runtime_name<'a>(&'a self, descriptor_id: &'a str) -> Option<&'a str> {
        match self {
            Self::DescriptorRuntime => Some(descriptor_id),
            Self::Runtime { name } => Some(name.as_str()),
            Self::None => None,
        }
    }

    fn is_descriptor_runtime(&self) -> bool {
        matches!(self, Self::DescriptorRuntime)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct AcpSessionConfigOptionBinding {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub option_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AcpSessionModelTransport {
    #[default]
    Disabled,
    SessionModel,
    ConfigOption {
        #[serde(flatten)]
        selector: AcpSessionConfigOptionBinding,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AcpSessionEffortTransport {
    #[default]
    Disabled,
    ConfigOption {
        #[serde(flatten)]
        selector: AcpSessionConfigOptionBinding,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct AcpSessionConfiguration {
    #[serde(default)]
    pub model: AcpSessionModelTransport,
    #[serde(default)]
    pub effort: AcpSessionEffortTransport,
    /// MCP servers offered to the agent on `session/new`.
    ///
    /// Http and Sse entries are dropped for agents that do not advertise the
    /// matching MCP capability, so a descriptor can list them unconditionally.
    ///
    /// Serializes with credentials blanked; see [`AcpMcpServer::redacted`].
    #[serde(
        default,
        skip_serializing_if = "Vec::is_empty",
        serialize_with = "serialize_mcp_servers_redacted"
    )]
    pub mcp_servers: Vec<AcpMcpServer>,
    /// Roots beyond the project directory the agent may work in, sent on
    /// `session/new` only when the agent advertises `additionalDirectories`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub additional_directories: Vec<String>,
}

impl AcpSessionConfiguration {
    fn is_empty(&self) -> bool {
        matches!(self.model, AcpSessionModelTransport::Disabled)
            && matches!(self.effort, AcpSessionEffortTransport::Disabled)
            && self.mcp_servers.is_empty()
            && self.additional_directories.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AcpAgentDescriptor {
    pub id: String,
    pub display_name: String,
    pub capabilities: Vec<CapabilityTag>,
    pub launch_command: String,
    pub launch_args: Vec<String>,
    pub env_passthrough: Vec<String>,
    #[serde(
        default,
        skip_serializing_if = "AcpSpawnConfiguration::is_descriptor_runtime"
    )]
    pub spawn_configuration: AcpSpawnConfiguration,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_catalog: Option<RuntimeModelCatalog>,
    #[serde(default)]
    pub install_hint: Option<String>,
    #[serde(default, skip_serializing_if = "AcpSessionConfiguration::is_empty")]
    pub session_configuration: AcpSessionConfiguration,
    pub doctor_probe: DoctorProbe,
    #[serde(default)]
    pub prompt_timeout_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub excluded_from_initial_default: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub bundled_with_harness: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpRuntimeProbeResponse {
    pub probes: Vec<AcpRuntimeProbe>,
    pub checked_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpRuntimeProbe {
    pub agent_id: String,
    pub display_name: String,
    pub binary_present: bool,
    pub auth_state: AcpAuthState,
    pub version: Option<String>,
    pub install_hint: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AcpAuthState {
    Ready,
    Unknown,
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AcpPermissionItem {
    pub request_id: String,
    pub session_id: String,
    pub tool_call: Value,
    pub options: Vec<AcpPermissionOption>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AcpPermissionOption {
    pub option_id: String,
    pub name: String,
    pub kind: AcpPermissionOptionKind,
    #[serde(default, rename = "_meta", skip_serializing_if = "Option::is_none")]
    pub meta: Option<Map<String, Value>>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AcpPermissionOptionKind {
    AllowOnce,
    AllowAlways,
    RejectOnce,
    RejectAlways,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AcpPermissionBatch {
    pub batch_id: String,
    pub acp_id: String,
    pub session_id: String,
    pub requests: Vec<AcpPermissionItem>,
    pub created_at: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum AcpPermissionDecision {
    ApproveAll,
    ApproveSome { request_ids: BTreeSet<String> },
    DenyAll,
}

impl AcpPermissionDecision {
    #[must_use]
    pub fn allows(&self, request_id: &str) -> bool {
        match self {
            Self::ApproveAll => true,
            Self::ApproveSome { request_ids } => request_ids.contains(request_id),
            Self::DenyAll => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct AcpAgentSnapshot {
    pub acp_id: String,
    pub session_id: String,
    pub agent_id: String,
    pub display_name: String,
    pub status: AgentStatus,
    pub pid: u32,
    pub pgid: i32,
    pub project_dir: String,
    pub process_key: String,
    pub pending_permissions: usize,
    pub permission_queue_depth: usize,
    pub pending_permission_batches: Vec<AcpPermissionBatch>,
    pub permission_mode: String,
    pub permission_log_path: Option<String>,
    pub terminal_count: usize,
    pub created_at: String,
    pub updated_at: String,
}

/// Result of the ACP `initialize` exchange with a live agent process.
#[expect(
    clippy::struct_excessive_bools,
    reason = "mirrors independent ACP capability flags; each bool is a distinct protocol capability"
)]
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentHandshake {
    pub protocol_version: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_title: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub auth_method_ids: Vec<String>,
    #[serde(default)]
    pub supports_load_session: bool,
    #[serde(default)]
    pub supports_session_list: bool,
    #[serde(default)]
    pub supports_session_resume: bool,
    #[serde(default)]
    pub supports_session_close: bool,
    #[serde(default)]
    pub supports_session_delete: bool,
    #[serde(default)]
    pub supports_additional_directories: bool,
    #[serde(default)]
    pub supports_mcp_http: bool,
    #[serde(default)]
    pub supports_mcp_sse: bool,
    #[serde(default)]
    pub supports_logout: bool,
}

/// Live per-session agent state assembled from ACP session notifications.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentSessionState {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub config_options: Vec<AcpSessionConfigOptionState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_mode_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub available_commands: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    /// Why the most recent prompt turn stopped, as reported by the agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_stop_reason: Option<String>,
}

/// One session an agent reports from `session/list`.
///
/// Distinct from a harness session: the agent owns these ids and may report
/// sessions harness never started, so callers treat the list as display data
/// rather than a source of harness session state.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpSessionSummary {
    pub session_id: String,
    pub cwd: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub additional_directories: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
}

/// One page of `session/list` results, carrying the agent's opaque cursor.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpSessionListPage {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sessions: Vec<AcpSessionSummary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

/// Compact view of one advertised session config option and its value.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpSessionConfigOptionState {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    pub current_value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpAgentInspectSnapshot {
    pub acp_id: String,
    pub session_id: String,
    pub agent_id: String,
    pub display_name: String,
    pub pid: u32,
    pub pgid: i32,
    pub process_key: String,
    pub uptime_ms: u64,
    pub last_update_at: String,
    pub last_client_call_at: Option<String>,
    pub watchdog_state: String,
    pub permission_mode: String,
    pub permission_log_path: Option<String>,
    pub pending_permissions: usize,
    pub permission_queue_depth: usize,
    pub terminal_count: usize,
    pub prompt_deadline_remaining_ms: u64,
    pub handshake: Option<AcpAgentHandshake>,
    pub session_state: Option<AcpAgentSessionState>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AcpAgentInspectResponse {
    pub agents: Vec<AcpAgentInspectSnapshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daemon_perceived_now: Option<String>,
    #[serde(default = "default_acp_inspect_available")]
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue_message: Option<String>,
}

#[derive(Clone, Serialize, PartialEq, Eq)]
pub struct BridgeAcpStartRequest {
    pub session_id: String,
    pub request: AcpAgentStartRequest,
    #[serde(default)]
    pub disable_pooling: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub openrouter_token: Option<String>,
}

impl fmt::Debug for BridgeAcpStartRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let redacted_token = self.openrouter_token.as_ref().map(|_| "[REDACTED]");
        formatter
            .debug_struct("BridgeAcpStartRequest")
            .field("session_id", &self.session_id)
            .field("request", &self.request)
            .field("disable_pooling", &self.disable_pooling)
            .field("openrouter_token", &redacted_token)
            .finish()
    }
}

pub(super) fn default_acp_role() -> SessionRole {
    SessionRole::Worker
}

pub(super) const fn default_acp_inspect_available() -> bool {
    true
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde skip_serializing_if callbacks receive field references"
)]
fn is_false(value: &bool) -> bool {
    !*value
}

