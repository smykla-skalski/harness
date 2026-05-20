//! Harness OpenRouter ACP shim library.
//!
//! Splits responsibilities into two layers:
//! - [`openrouter`] — async HTTP client for OpenRouter's Chat Completions API
//!   plus the per-key model list endpoint.
//! - [`acp`] — ACP agent server that translates between ACP JSON-RPC over
//!   stdio and OpenRouter HTTP/SSE.

pub mod acp;
pub mod openrouter;
