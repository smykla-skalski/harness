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
//!
//! Orchestration lifecycle contract:
//! - Spawn intent starts in the daemon control plane. ACP runtimes never self-
//!   register into session state and never run `session join` on their own.
//! - `local_runtime` allocates a fresh logical ACP id for every start request,
//!   even when the underlying process is reused from the pool.
//! - After the protocol task is attached, the manager writes a canonical
//!   `AgentRegistration` keyed by `ManagedAgentRef::acp(acp_id)` into session
//!   orchestration before the runtime is allowed to proceed.
//! - The protocol start gate is released only after that registration exists,
//!   so `session/new` can always bind back to a known orchestration agent.
//! - `session/new` completion then records the ACP runtime session id on that
//!   same managed-agent registration; reused logical sessions already have that
//!   id in hand before registration, so they persist it as part of the initial
//!   join write instead of a follow-up mutation. Async daemon DB paths must not
//!   block the protocol reactor while doing so.
//! - Disconnect propagation flows back through session orchestration with the
//!   concrete `DisconnectReason`, so task release, degraded-leader handling,
//!   and restart eligibility stay owned by the session service rather than ACP-
//!   specific shadow state.
//! - Pool reuse is process-level only. Each reused logical session still gets a
//!   fresh orchestration registration, and failure to register must detach the
//!   logical ACP session again so pooled state does not drift.
//! - Session-bound ACP starts default to isolated process keys today. If pooled
//!   session-bound starts are re-enabled later, they must preserve the same
//!   per-logical-session registration and disconnect guarantees.

mod active;
mod local_runtime;
mod manager;
mod permission_bridge;
mod pool_key;
mod prompt_gate;
mod protocol;
mod sandbox_proxy;

pub use manager::{
    AcpAgentInspectResponse, AcpAgentInspectSnapshot, AcpAgentManagerHandle, AcpAgentSnapshot,
    AcpAgentStartRequest,
};
pub use permission_bridge::{AcpPermissionBatch, AcpPermissionDecision, AcpPermissionItem};
