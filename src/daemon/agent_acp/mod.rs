//! Daemon-owned ACP agent sessions.
//!
//! This module is intentionally shaped around ACP needs: process supervision,
//! permission queueing, and live session observability. It does not mirror the
//! PTY-oriented `agent_tui` manager.

mod active;
mod local_runtime;
mod manager;
mod permission_bridge;
mod pool_key;
mod protocol;
mod sandbox_proxy;

pub use manager::{
    AcpAgentInspectResponse, AcpAgentInspectSnapshot, AcpAgentManagerHandle, AcpAgentSnapshot,
    AcpAgentStartRequest,
};
pub use permission_bridge::{AcpPermissionBatch, AcpPermissionDecision, AcpPermissionItem};
