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
    /// Catch-all for runtime-specific events.
    Other { label: String, data: Value },
}
