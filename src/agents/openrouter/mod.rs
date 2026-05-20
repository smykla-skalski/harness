//! `OpenRouter` HTTP/JSON client used by the daemon's `OpenRouter` agent backend.
//!
//! Layout:
//! - [`types`] — wire types for the OpenAI-compatible Chat Completions schema
//!   plus `OpenRouter`'s `reasoning` / model-listing extensions.
//! - [`client`] — async [`OpenRouterClient`] backed by `reqwest`. Streams chat
//!   completions as a [`futures_util::Stream`] of parsed chunks; also lists
//!   models for the per-key catalog.
//! - [`errors`] — [`OpenRouterError`] with HTTP-status classification (rate
//!   limit, auth, moderation, overload, generic).
//! - [`config`] — environment-derived configuration (`OPENROUTER_API_KEY`,
//!   `OPENROUTER_API_URL`, attribution headers).

pub mod client;
pub mod config;
pub mod errors;
pub mod types;

pub use client::OpenRouterClient;
pub use config::{AgentConfig, ConfigError};
pub use errors::{OpenRouterError, classify_status, parse_retry_after};
pub use types::{
    AssistantToolCall, AssistantToolCallFunction, AssistantToolCallKind, ChatChoiceDelta,
    ChatChoiceStreamEvent, ChatMessage, ChatRequest, ChatRole, FinishReason, ModelEntry,
    ModelListResponse, ReasoningRequest, StreamChunk, ToolCallDelta, ToolCallFunctionDelta,
    ToolChoice, ToolChoiceFunction, ToolChoiceMode, ToolDefinition, ToolDefinitionFunction,
    ToolDefinitionKind, Usage,
};
