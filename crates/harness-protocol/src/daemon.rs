use std::collections::BTreeMap;
use std::fmt::{self, Display, Formatter};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Canonical daemon HTTP paths used by standalone clients, re-exported from
/// `api_contract::http_paths`'s full route-path list so this crate carries
/// one definition of each path instead of a hand-synced subset.
pub mod http_paths {
    pub use super::api_contract::http_paths::{HEADLESS_READINESS, WS};
}

/// Daemon HTTP/WS wire-protocol version. Canonical here rather than in
/// `harness-daemon`: `harness-session::transport` needs it for the
/// headless-readiness request without depending back on the daemon crate, and
/// the daemon itself now resolves this constant from here directly instead of
/// carrying its own hand-synced copy.
pub const DAEMON_WIRE_VERSION: u32 = 5;

/// Wire request for a headless execution readiness check.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct HeadlessReadinessRequest {
    pub client_version: String,
    pub client_wire_version: u32,
    pub runtime: String,
    pub model: String,
    #[serde(default)]
    pub lane: Option<String>,
}

/// Wire response for a headless execution readiness check.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "the wire report preserves each independently actionable readiness result"
)]
pub struct HeadlessReadinessReport {
    pub ready: bool,
    pub client: HeadlessReadinessPeer,
    pub daemon: HeadlessReadinessPeer,
    pub compatible: bool,
    pub bridge_reachable: bool,
    pub lanes: Vec<HeadlessReadinessLane>,
    pub selected_lane: String,
    pub credential: HeadlessReadinessCredential,
    pub runtime: HeadlessReadinessRuntime,
    pub model: HeadlessReadinessModel,
    pub orchestrator_active: bool,
    pub unmet_requirements: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct HeadlessReadinessPeer {
    pub version: String,
    pub wire_version: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct HeadlessReadinessLane {
    pub name: String,
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct HeadlessReadinessCredential {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    pub required: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub configured: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct HeadlessReadinessRuntime {
    pub requested: String,
    pub available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct HeadlessReadinessModel {
    pub requested: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effective: Option<String>,
    pub available: bool,
}

/// Canonical websocket method names shared with the daemon router.
pub mod ws_methods;

/// Bounds the daemon holds every task-board list read to. Lives directly in
/// this crate (rather than a root-crate `#[path]` include) so a standalone
/// client and `harness-task-board`'s own query code share the one definition
/// instead of each carrying a copy.
pub mod task_board_list_bounds;

pub use task_board_list_bounds::{
    TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_CURSOR_CHARS, TASK_BOARD_LIST_MAX_LIMIT,
    TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS,
};

/// Reviews wire types, relocated from `harness-reviews` (see the module's
/// own doc comment for why).
pub mod reviews;

/// The whole-API HTTP<->WS route contract, relocated from `harness-daemon`'s
/// `daemon::protocol::api_contract` (zero internal dependencies made it
/// relocatable; that crate re-exports every item unchanged at the original
/// path).
pub mod api_contract;

/// Harness Monitor audit-event DTOs. Pure data with no dependency beyond
/// `serde`/`serde_json`, so they live here rather than in the daemon crate
/// that used to define them, letting `db` and the rest of the daemon share
/// one definition instead of `db` reaching back into the daemon for it.
pub mod audit;

/// Voice-session wire types (start/stop a session, stream audio chunks and
/// transcript updates), relocated from `harness-daemon`'s
/// `daemon::protocol::voice`. Pure data with no daemon-only dependency.
pub mod voice;

/// `OpenRouter` model-catalog wire types, relocated from `harness-daemon`'s
/// `daemon::protocol::openrouter_models`. Pure data with no daemon-only
/// dependency.
pub mod openrouter_models;

/// Daemon health, readiness, log-level, telemetry, and ACP-transcript wire
/// types free of daemon-only state, relocated from `harness-daemon`'s
/// `daemon::protocol::summaries`. That module keeps the daemon-state-carrying
/// remainder (the diagnostics report and its GitHub rate-limit fields) and
/// the timeline pagination types tracked separately by issue #1102.
pub mod summaries;

/// Task-board wire types, relocated from `harness-task-board` (see the
/// module's own doc comment for why).
pub mod task_board;

// Kept in sync by hand with `api_contract`'s route-table-derived
// `task_board_mcp_methods()`, which never chains in
// `routes_task_board_orchestrator` or `routes_task_board_working_copies` --
// those routes are deliberately absent from the MCP surface.
const NON_AGENT_FACING_TASK_BOARD_METHODS: &[&str] = &[
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
    ws_methods::TASK_BOARD_ORCHESTRATOR_METRICS,
    ws_methods::TASK_BOARD_ORCHESTRATOR_FORCE_CANCEL,
    ws_methods::TASK_BOARD_WORKING_COPIES_LIST,
    ws_methods::TASK_BOARD_WORKING_COPIES_OBTAIN,
    ws_methods::TASK_BOARD_WORKING_COPIES_DELETE,
];

/// Return websocket methods belonging to the task-board and policy surfaces.
#[must_use]
pub fn task_board_mcp_methods() -> Vec<&'static str> {
    ws_methods::ALL
        .iter()
        .copied()
        .filter(|method| {
            (method.starts_with("task_board.") || method.starts_with("policy_"))
                && !NON_AGENT_FACING_TASK_BOARD_METHODS.contains(method)
        })
        .collect()
}

/// One request sent over the daemon websocket.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsRequest {
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trace_context: Option<BTreeMap<String, String>>,
}

/// One response received from the daemon websocket.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsResponse {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<WsErrorPayload>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub batch_index: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub batch_count: Option<usize>,
}

/// Structured error payload returned by the daemon websocket.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsErrorPayload {
    pub code: String,
    pub message: String,
    #[serde(default)]
    pub details: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_code: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// One event published on the daemon's shared observation stream.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamEvent {
    pub event: String,
    pub recorded_at: String,
    pub session_id: Option<String>,
    pub payload: Value,
}

/// Which entry point owns this daemon process.
///
/// Managed daemons are launched by `SMAppService` from the bundled Harness
/// Monitor app. External daemons are launched by `harness-daemon dev` from a
/// CLI shell. The two kinds run side-by-side without colliding because they
/// keep their state in separate `<root>/daemon/<ownership>/` subtrees and use
/// distinct launchd labels and bridge ports.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[derive(utoipa::ToSchema)]
pub enum DaemonOwnership {
    #[default]
    Managed,
    External,
}

impl DaemonOwnership {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Managed => "managed",
            Self::External => "external",
        }
    }

    /// Parse a value from the `HARNESS_DAEMON_OWNERSHIP` env or a manifest
    /// JSON string. Case-insensitive; trims whitespace. Returns `None` for
    /// unrecognized values so callers can decide how to default.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "managed" => Some(Self::Managed),
            "external" => Some(Self::External),
            _ => None,
        }
    }
}

impl Display for DaemonOwnership {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default, utoipa::ToSchema)]
pub struct HostBridgeCapabilityManifest {
    #[serde(default = "default_host_bridge_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub healthy: bool,
    pub transport: String,
    #[serde(default)]
    pub endpoint: Option<String>,
    #[serde(default)]
    pub metadata: BTreeMap<String, String>,
}

fn default_host_bridge_enabled() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default, utoipa::ToSchema)]
pub struct HostBridgeManifest {
    #[serde(default)]
    pub running: bool,
    #[serde(default)]
    pub socket_path: Option<String>,
    #[serde(default)]
    pub capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonBinaryStamp {
    pub helper_path: String,
    pub device_identifier: u64,
    pub inode: u64,
    pub file_size: u64,
    pub modification_time_interval_since_1970: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonManifest {
    pub version: String,
    pub pid: u32,
    pub endpoint: String,
    pub started_at: String,
    pub token_path: String,
    #[serde(default)]
    pub sandboxed: bool,
    #[serde(default)]
    pub host_bridge: HostBridgeManifest,
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub updated_at: String,
    #[serde(default)]
    pub binary_stamp: Option<DaemonBinaryStamp>,
    /// Which entry point launched this daemon. Defaults to `Managed` for
    /// pre-coexistence manifests so legacy installs deserialize cleanly.
    #[serde(default)]
    pub ownership: DaemonOwnership,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonAuditEvent {
    pub recorded_at: String,
    pub level: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonDiagnostics {
    pub daemon_root: String,
    pub manifest_path: String,
    pub auth_token_path: String,
    pub auth_token_present: bool,
    pub events_path: String,
    pub database_path: String,
    pub database_size_bytes: u64,
    pub last_event: Option<DaemonAuditEvent>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{WsRequest, http_paths, task_board_mcp_methods, ws_methods};

    #[test]
    fn task_board_request_matches_daemon_wire_shape() {
        let request = WsRequest {
            id: "mcp-1".to_string(),
            method: ws_methods::TASK_BOARD_LIST.to_string(),
            params: json!({ "status": "todo" }),
            trace_context: None,
        };

        assert_eq!(http_paths::WS, "/v1/ws");
        assert!(task_board_mcp_methods().contains(&ws_methods::POLICY_PIPELINE_SAVE_DRAFT));
        assert_eq!(
            serde_json::to_value(request).expect("serialize request"),
            json!({
                "id": "mcp-1",
                "method": "task_board.list",
                "params": { "status": "todo" }
            })
        );
    }

    #[test]
    fn observability_methods_are_wire_contracts_not_mcp_tools() {
        let agent_methods = task_board_mcp_methods();

        for method in [
            ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
            ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
            ws_methods::TASK_BOARD_ORCHESTRATOR_METRICS,
            ws_methods::TASK_BOARD_ORCHESTRATOR_FORCE_CANCEL,
            ws_methods::TASK_BOARD_WORKING_COPIES_LIST,
            ws_methods::TASK_BOARD_WORKING_COPIES_OBTAIN,
            ws_methods::TASK_BOARD_WORKING_COPIES_DELETE,
        ] {
            assert!(ws_methods::ALL.contains(&method));
            assert!(!agent_methods.contains(&method));
        }
    }
}
