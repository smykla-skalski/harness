use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Normalized conversation event produced by all runtime adapters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationEvent {
    /// When this event occurred (from the agent's transcript).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    /// Monotonic sequence within the session (assigned by the parser).
    pub sequence: u64,
    /// What kind of event this is.
    pub kind: ConversationEventKind,
    /// The agent that produced this event.
    pub agent: String,
    /// Session identifier.
    pub session_id: String,
}

/// Discriminated event kinds.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ConversationEventKind {
    /// User submitted a prompt.
    UserPrompt { content: String },
    /// Assistant produced text output.
    AssistantText { content: String },
    /// Agent invoked a tool.
    ToolInvocation {
        tool_name: String,
        category: String,
        input: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        invocation_id: Option<String>,
    },
    /// Tool returned a result.
    ToolResult {
        tool_name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        invocation_id: Option<String>,
        output: Value,
        is_error: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        duration_ms: Option<u64>,
    },
    /// Agent encountered an error.
    Error {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        code: Option<String>,
        message: String,
        recoverable: bool,
    },
    /// Agent state transition.
    StateChange { from: String, to: String },
    /// A file was modified during this event.
    FileModification { path: PathBuf, operation: String },
    /// Session lifecycle marker (start, stop, resume).
    SessionMarker { marker: String },
    /// Signal received and processed by the agent.
    SignalReceived { signal_id: String, command: String },
    /// Watchdog state transition emitted by the ACP supervisor.
    WatchdogState {
        from: String,
        to: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// Permission prompt surfaced to the user by the ACP client gate. Emitted
    /// from `HarnessAcpClient::handle_request_permission` so the timeline
    /// shows the moment the agent asked, regardless of how the user later
    /// decides.
    PermissionAsked {
        tool: String,
        scope: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
    },
    /// Wake-prompt context acknowledged by the agent. Emitted from the wake-
    /// accept path in `daemon::agent_acp::manager::session_access` once the
    /// agent's `session/prompt` ack lands, so the timeline shows that the
    /// dispatched context was received instead of leaving the operator to
    /// infer it from the daemon log.
    ContextInjected {
        actor: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        summary: Option<String>,
    },
    // NOTE: `HookFired` was previously defined here but stays removed.
    // Hooks in this codebase live in `src/hooks/runtime/mod.rs` and run
    // CLI-side around shell tool calls; there is no agent-side ACP path
    // that fires a hook on behalf of the model. Reintroduce only when an
    // agent-side hook surface lands with a real producer per the UI shape
    // rule in `apps/harness-monitor/CLAUDE.md` ("no UI surface
    // ships without its real producer").
    /// Catch-all for runtime-specific events.
    Other { label: String, data: Value },
}
