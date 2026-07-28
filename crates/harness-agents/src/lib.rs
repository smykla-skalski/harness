//! Shared agent lifecycle: canonical agent ledger/session storage,
//! project-scoped agent state, runtime adapters for log discovery, signal
//! delivery, liveness detection, and write-surface policy.
//!
//! The Agent Client Protocol client (`agents::acp`) stays in the root crate
//! for now: it is the largest, most self-contained subtree and is tracked as
//! its own extraction. Its remaining cross-references into this crate
//! (`policy`, `runtime::event`, `runtime::models`, `kind`) resolve through
//! the root crate's `pub use harness_agents::*;` facade the same way every
//! other external consumer's `crate::agents::` path does.

#![deny(unsafe_code)]

// Deliberate public API facade, not scaffolding: `harness::agents::kind`
// stays a stable path for the root crate's existing callers (and for
// `agents::acp`, which stays behind in the root crate). The physical
// `kind/mod.rs` and `kind/disconnect.rs` files are not part of this crate's
// build; `harness-protocol` alone pulls them in with `#[path]` to give
// `AcpAgentId`/`DisconnectReason`/`RuntimeKind` their one physical
// definition.
pub mod kind {
    pub use harness_protocol::agent::{AcpAgentId, DisconnectReason, RuntimeKind};
}
pub mod policy;
pub mod runtime;
pub mod service;
pub mod storage;
mod types;
