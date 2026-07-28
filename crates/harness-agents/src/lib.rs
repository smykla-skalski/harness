//! Shared agent lifecycle: canonical agent ledger/session storage,
//! project-scoped agent state, runtime adapters for log discovery, signal
//! delivery, liveness detection, write-surface policy, and the Agent Client
//! Protocol client.
//!
//! `acp` is gated behind the `bridge-runtime` feature: it pulls in
//! `agent-client-protocol`, `nix`, and `portable-pty`, which callers that
//! only need `policy`/`runtime`/`storage`/`kind` (`harness-hook`) have no
//! reason to build. `harness-daemon` and `harness-bridge` request the
//! feature explicitly; the root crate forwards its own `bridge-runtime`
//! feature onto it the same way.

#![deny(unsafe_code)]

#[cfg(feature = "bridge-runtime")]
pub mod acp;
// Deliberate public API facade, not scaffolding: `harness::agents::kind`
// stays a stable path for the root crate's existing callers and for `acp`.
// The physical `kind/mod.rs` and `kind/disconnect.rs` files are not part of
// this crate's build; `harness-protocol` alone pulls them in with `#[path]`
// to give `AcpAgentId`/`DisconnectReason`/`RuntimeKind` their one physical
// definition.
pub mod kind {
    pub use harness_protocol::agent::{AcpAgentId, DisconnectReason, RuntimeKind};
}
pub mod policy;
pub mod runtime;
pub mod service;
pub mod storage;
mod types;
