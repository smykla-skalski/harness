#[path = "../../../../src/agents/acp/mod.rs"]
pub mod acp;

pub mod kind {
    pub use harness_protocol::agent::{AcpAgentId, DisconnectReason, RuntimeKind};
}

#[path = "../../../../src/agents/policy.rs"]
pub mod policy;
#[path = "../../../../src/agents/runtime/mod.rs"]
pub mod runtime;
