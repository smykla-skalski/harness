//! Agent Client Protocol managed-agent wire models.

mod mcp;
mod models;
mod permission_wire;
mod request_wire;
mod snapshot_wire;
mod wire;

pub use mcp::{AcpMcpEnvVariable, AcpMcpHttpHeader, AcpMcpServer};
pub use models::{
    AcpAgentDescriptor, AcpAgentHandshake, AcpAgentInspectResponse, AcpAgentInspectSnapshot,
    AcpAgentSessionState, AcpAgentSnapshot, AcpAgentStartRequest, AcpAuthState, AcpEndpoint,
    AcpPermissionBatch, AcpPermissionDecision, AcpPermissionItem, AcpPermissionOption,
    AcpPermissionOptionKind, AcpRuntimeProbe, AcpRuntimeProbeResponse,
    AcpSessionConfigOptionBinding, AcpSessionConfigOptionState, AcpSessionConfiguration,
    AcpSessionEffortTransport, AcpSessionListPage, AcpSessionModelTransport, AcpSessionSummary,
    AcpSpawnConfiguration, BridgeAcpStartRequest, CapabilityTag, DoctorProbe,
};
