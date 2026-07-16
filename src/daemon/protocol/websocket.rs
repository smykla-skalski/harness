use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use harness_protocol::daemon::{WsErrorPayload, WsRequest, WsResponse};

#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
use crate::agents::acp::catalog::AcpAgentDescriptor;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
use crate::agents::acp::probe::AcpRuntimeProbeResponse;
use crate::agents::runtime::models::RuntimeModelCatalog;
use crate::daemon::agent_acp::AcpAgentInspectResponse;
use crate::session::types::AgentPersona;
#[cfg(not(any(feature = "bridge-runtime", feature = "daemon-runtime")))]
use harness_protocol::managed_agents::acp::{AcpAgentDescriptor, AcpRuntimeProbeResponse};

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
    #[serde(default)]
    pub acp_agents: Vec<AcpAgentDescriptor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime_probe: Option<AcpRuntimeProbeResponse>,
}

/// Event name used for the initial configuration push.
pub const WS_CONFIG_EVENT: &str = "config";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WsRuntimeProbeUpdate {
    pub probe: AcpRuntimeProbeResponse,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WsAcpInspect {
    pub inspect: AcpAgentInspectResponse,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeMap;

    fn accept_canonical_request(_request: harness_protocol::daemon::WsRequest) {}

    #[test]
    fn ws_request_serializes_trace_context_when_present() {
        let request = WsRequest {
            id: "req-1".to_string(),
            method: "session.detail".to_string(),
            params: json!({ "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc" }),
            trace_context: Some(BTreeMap::from([(
                "traceparent".to_string(),
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01".to_string(),
            )])),
        };

        let serialized = serde_json::to_value(&request).expect("serialize websocket request");

        accept_canonical_request(request);

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
