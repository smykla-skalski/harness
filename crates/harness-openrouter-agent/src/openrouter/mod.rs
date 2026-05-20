//! OpenRouter HTTP/JSON client used by the ACP shim.
//!
//! Layout mirrors the daemon's original module so the port stays a 1:1 copy
//! that can be removed from the daemon once the shim is the only consumer.

pub mod client;
pub mod config;
pub mod errors;
pub mod types;

pub use client::OpenRouterClient;
pub use config::{AgentConfig, ConfigError, discard_api_key_file};
pub use errors::{OpenRouterError, classify_status, parse_retry_after};
pub use types::{
    AssistantToolCall, AssistantToolCallFunction, AssistantToolCallKind, ChatChoiceDelta,
    ChatChoiceStreamEvent, ChatMessage, ChatRequest, ChatRole, FinishReason, ModelEntry,
    ModelListResponse, ReasoningRequest, StreamChunk, ToolCallDelta, ToolCallFunctionDelta,
    ToolChoice, ToolChoiceFunction, ToolChoiceMode, ToolDefinition, ToolDefinitionFunction,
    ToolDefinitionKind, Usage,
};
