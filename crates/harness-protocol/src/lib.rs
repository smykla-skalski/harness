#![deny(unsafe_code)]

mod agent_models;
#[path = "../../../src/agents/runtime/event.rs"]
mod conversation_event;
#[path = "../../../src/agents/kind/mod.rs"]
mod runtime_kind;

/// Canonical agent identities and transport-neutral wire models.
pub mod agent {
    pub use crate::agent_models::{
        AckResult, DeliveryConfig, HookAgent, HookIntegrationDescriptor, RuntimeCapabilities,
        Signal, SignalAck, SignalPayload, SignalPriority, hook_agent_for_runtime_name,
        signal_matches_session,
    };
    pub use crate::conversation_event::{ConversationEvent, ConversationEventKind};
    pub use crate::runtime_kind::{AcpAgentId, DisconnectReason, RuntimeKind};
}

/// Daemon websocket contracts shared by standalone Harness clients.
pub mod daemon;
/// Managed-agent request and response contracts shared by daemon clients.
pub mod managed_agents;

// Compatibility namespaces for the canonical session model sources. They
// intentionally expose only protocol models, never application/runtime code.
#[doc(hidden)]
pub mod agents {
    pub mod kind {
        pub use crate::agent::{AcpAgentId, DisconnectReason, RuntimeKind};
    }

    pub mod runtime {
        pub use crate::agent::{
            HookIntegrationDescriptor, RuntimeCapabilities, hook_agent_for_runtime_name,
        };

        pub mod signal {
            pub use crate::agent::{
                AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
                signal_matches_session,
            };
        }
    }
}

#[doc(hidden)]
pub mod hooks {
    pub mod adapters {
        pub use crate::agent::HookAgent;
    }
}

#[path = "../../../src/session/types/mod.rs"]
pub mod session;
