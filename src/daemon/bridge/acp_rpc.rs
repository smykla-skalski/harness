use serde::{Deserialize, Serialize};

use crate::daemon::agent_acp::AcpPermissionDecision;
use crate::daemon::protocol::StreamEvent;
use harness_protocol::managed_agents::acp::AcpRuntimeProbeResponse;

pub(super) use harness_protocol::managed_agents::acp::BridgeAcpStartRequest;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(super) struct BridgeAcpProbeRequest {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAcpProbeResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) probe: Option<AcpRuntimeProbeResponse>,
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
