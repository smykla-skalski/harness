//! Agent Client Protocol managed-agent wire models.

mod models;
mod permission_wire;
mod request_wire;
mod snapshot_wire;
mod wire;

pub use models::{
    AcpAgentDescriptor, AcpAgentHandshake, AcpAgentInspectResponse, AcpAgentInspectSnapshot,
    AcpAgentSnapshot, AcpAgentStartRequest, AcpAuthState, AcpPermissionBatch,
    AcpPermissionDecision, AcpPermissionItem, AcpPermissionOption, AcpPermissionOptionKind,
    AcpRuntimeProbe, AcpRuntimeProbeResponse, AcpSessionConfigOptionBinding,
    AcpSessionConfiguration, AcpSessionEffortTransport, AcpSessionModelTransport,
    AcpSpawnConfiguration, BridgeAcpStartRequest, CapabilityTag, DoctorProbe,
};
