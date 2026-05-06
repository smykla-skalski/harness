use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize};

use crate::daemon::agent_acp::{AcpAgentStartRequest, AcpPermissionDecision};
use crate::daemon::protocol::StreamEvent;

#[derive(Debug, Clone, Serialize)]
pub(super) struct BridgeAcpStartRequest {
    pub(super) session_id: String,
    pub(super) request: AcpAgentStartRequest,
    #[serde(default)]
    pub(super) disable_pooling: bool,
}

#[derive(Deserialize)]
struct BridgeAcpStartRequestDecode {
    session_id: String,
    request: serde_json::Value,
    #[serde(default)]
    disable_pooling: bool,
}

impl<'de> Deserialize<'de> for BridgeAcpStartRequest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let mut decoded = BridgeAcpStartRequestDecode::deserialize(deserializer)?;
        if let Some(request) = decoded.request.as_object_mut()
            && !request.contains_key("descriptor_id")
            && let Some(agent) = request.remove("agent")
        {
            request.insert("descriptor_id".to_string(), agent);
        }
        let request = serde_json::from_value(decoded.request).map_err(D::Error::custom)?;
        Ok(Self {
            session_id: decoded.session_id,
            request,
            disable_pooling: decoded.disable_pooling,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAcpListRequest {
    pub(super) session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAcpInspectRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(super) struct BridgeAcpReconcileRequest {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAcpGetRequest {
    pub(super) acp_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAcpResolvePermissionRequest {
    pub(super) acp_id: String,
    pub(super) batch_id: String,
    pub(super) decision: AcpPermissionDecision,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAcpEventsRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) after_seq: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) known_epoch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) known_continuity: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct BridgeAcpEventsResponse {
    pub(crate) bridge_epoch: String,
    pub(crate) continuity: u64,
    pub(crate) daemon_perceived_now: String,
    pub(crate) next_seq: u64,
    pub(crate) truncated: bool,
    pub(crate) requires_resync: bool,
    pub(crate) events: Vec<StreamEvent>,
}
