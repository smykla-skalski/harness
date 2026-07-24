//! Agent Client Protocol managed-agent wire models.

mod mcp;
mod models;
mod permission_wire;
mod request_wire;
#[cfg(feature = "openapi")]
mod schema;
mod snapshot_wire;
mod wire;

pub use mcp::{AcpMcpEnvVariable, AcpMcpHttpHeader, AcpMcpServer};
#[cfg(feature = "openapi")]
pub use schema::{
    AcpAgentInspectSnapshotSchema, AcpAgentSnapshotSchema, AcpAgentStartRequestSchema,
    AcpPermissionBatchSchema,
};
pub use models::{
    AcpAgentDescriptor, AcpAgentHandshake, AcpAgentInspectResponse, AcpAgentInspectSnapshot,
    AcpAgentSessionState, AcpAgentSnapshot, AcpAgentStartRequest, AcpAuthState, AcpEndpoint,
    AcpPermissionBatch, AcpPermissionDecision, AcpPermissionItem, AcpPermissionOption,
    AcpPermissionOptionKind, AcpRuntimeProbe, AcpRuntimeProbeResponse,
    AcpSessionConfigOptionBinding, AcpSessionConfigOptionState, AcpSessionConfiguration,
    AcpSessionEffortTransport, AcpSessionListPage, AcpSessionModelTransport, AcpSessionSummary,
    AcpSpawnConfiguration, BridgeAcpStartRequest, CapabilityTag, DoctorProbe,
};
