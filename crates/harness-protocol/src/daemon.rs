use std::collections::BTreeMap;

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

const NON_AGENT_FACING_TASK_BOARD_METHODS: &[&str] = &[
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
    ws_methods::TASK_BOARD_ORCHESTRATOR_METRICS,
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
        ] {
            assert!(ws_methods::ALL.contains(&method));
            assert!(!agent_methods.contains(&method));
        }
    }
}
