use std::collections::BTreeMap;
use std::fmt::{self, Display, Formatter};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Canonical daemon HTTP paths used by standalone clients.
pub mod http_paths {
    /// Authenticated daemon websocket endpoint.
    pub const WS: &str = "/v1/ws";
}

/// Canonical websocket method names shared with the daemon router.
#[path = "../../../src/daemon/protocol/api_contract/ws_methods.rs"]
pub mod ws_methods;

/// Bounds the daemon holds every task-board list read to. Shared as one source
/// file so a standalone client advertises the same numbers the daemon enforces.
#[path = "../../../src/task_board/item_query_bounds.rs"]
pub mod task_board_list_bounds;

pub use task_board_list_bounds::{
    TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_CURSOR_CHARS, TASK_BOARD_LIST_MAX_LIMIT,
    TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS,
};

// Kept in sync by hand with `src/daemon/protocol/api_contract.rs`'s
// route-table-derived `task_board_mcp_methods()`, which never chains in
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[derive(utoipa::ToSchema)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[derive(utoipa::ToSchema)]
pub struct HostBridgeManifest {
    #[serde(default)]
    pub running: bool,
    #[serde(default)]
    pub socket_path: Option<String>,
    #[serde(default)]
    pub capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct DaemonBinaryStamp {
    pub helper_path: String,
    pub device_identifier: u64,
    pub inode: u64,
    pub file_size: u64,
    pub modification_time_interval_since_1970: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct DaemonAuditEvent {
    pub recorded_at: String,
    pub level: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
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
