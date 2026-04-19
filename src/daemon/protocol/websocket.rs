use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

use crate::agents::runtime::models::RuntimeModelCatalog;
use crate::session::types::AgentPersona;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsRequest {
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trace_context: Option<BTreeMap<String, String>>,
}

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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsErrorPayload {
    pub code: String,
    pub message: String,
    #[serde(default)]
    pub details: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsPushEvent {
    pub event: String,
    pub recorded_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub payload: Value,
    pub seq: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsChunkFrame {
    pub chunk_id: String,
    pub chunk_index: usize,
    pub chunk_count: usize,
    pub chunk_base64: String,
}

/// Initial configuration payload pushed as the first WebSocket frame after
/// upgrade. The Swift client must receive and process this before any other
/// traffic so personas and per-runtime model catalogs are available before the
/// user can start an agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WsConfigPayload {
    pub personas: Vec<AgentPersona>,
    pub runtime_models: Vec<RuntimeModelCatalog>,
}

/// Event name used for the initial configuration push.
pub const WS_CONFIG_EVENT: &str = "config";

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeMap;

    #[test]
    fn ws_request_serializes_trace_context_when_present() {
        let request = WsRequest {
            id: "req-1".to_string(),
            method: "session.detail".to_string(),
            params: json!({ "session_id": "sess-1" }),
            trace_context: Some(BTreeMap::from([(
                "traceparent".to_string(),
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01".to_string(),
            )])),
        };

        let serialized = serde_json::to_value(&request).expect("serialize websocket request");

        assert_eq!(
            serialized["trace_context"]["traceparent"],
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        );
    }

    #[test]
    fn ws_request_defaults_trace_context_to_none_when_absent() {
        let request: WsRequest = serde_json::from_value(json!({
            "id": "req-2",
            "method": "stream.subscribe",
            "params": {
                "scope": "global"
            }
        }))
        .expect("deserialize websocket request");

        assert!(request.trace_context.is_none());
    }
}
