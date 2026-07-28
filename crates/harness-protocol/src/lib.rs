#![deny(unsafe_code)]

mod agent_models;
#[path = "../../../src/agents/runtime/event.rs"]
mod conversation_event;
mod hook_prompts;
mod hook_session;
mod observe_classification;
mod observe_issue_code;
mod observe_state;
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

/// `AskUserQuestion` prompt models and the `SessionStart` hook output
/// contract, shared by hook adapters and their daemon-facing summaries.
pub mod hook {
    pub use crate::hook_prompts::{AskUserQuestionOption, AskUserQuestionPrompt};
    pub use crate::hook_session::{SessionStartHookOutput, SessionStartHookSpecificOutput};
}

/// Observer-state classification, issue identity, and the on-disk event
/// record shared by the CLI observer loop and the daemon.
pub mod observe {
    pub use crate::observe_classification::{FixSafety, IssueCategory, IssueSeverity};
    pub use crate::observe_issue_code::IssueCode;
    pub use crate::observe_state::{
        ActiveWorker, AgentObserveRecord, AttemptResult, IssueAttempt, ObserverState,
        ObserverStateEvent, OpenIssue,
    };
}

/// Daemon websocket contracts shared by standalone Harness clients.
pub mod daemon;
/// Session observation timeline contracts.
pub mod timeline;
/// Managed-agent request and response contracts shared by daemon clients.
pub mod managed_agents;
/// Session request/response and on-disk registry contracts shared by daemon
/// clients that talk to a session directly.
pub mod session_wire;
/// Session-id resolution shared by every binary that hosts a `HookAgent`.
pub mod session_resolution;

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
