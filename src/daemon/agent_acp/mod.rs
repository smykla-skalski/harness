//! Daemon-owned ACP agent sessions.
//!
//! This module is intentionally shaped around ACP needs: process supervision,
//! permission queueing, and live session observability. It does not mirror the
//! PTY-oriented `agent_tui` manager.
//!
//! ACP multiplexing protocol table (phase-1 text mode):
//! - Request routing: every session-scoped ACP request must carry `session_id`
//!   and must pass `protocol::session_guard` stale-id validation.
//! - Notification routing: notifications are accepted only for registered live
//!   ACP session ids; stale/unknown ids fail closed.
//! - Prompt admission: one in-flight prompt per ACP protocol connection; owner
//!   timeout maps to `PromptTimeout`.
//! - Permission ownership: batching and timeout events are session-local in
//!   `permission_bridge`; no cross-session coalescing.
//! - Stop/cancel isolation: explicit stop maps to `SessionStopped` and does
//!   not implicitly mutate other logical sessions.
//! - Process incidents: bridge continuity/resync desync emits
//!   `acp_bridge_resync_incident` with `kind=protocol_desync`.

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
