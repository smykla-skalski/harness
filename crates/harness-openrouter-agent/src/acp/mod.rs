//! ACP agent-side bridge: speaks JSON-RPC over stdio with the harness daemon.
//!
//! The bridge owns one `OpenRouterClient` per session, drives streaming Chat
//! Completions, and translates ACP `session/prompt` requests + ACP tool
//! permissions into the OpenRouter wire protocol. Tool calls fan out to the
//! client side (the daemon) via the standard ACP `read_text_file`,
//! `write_text_file`, `create_terminal`, `terminal_output`, `request_permission`
//! request methods.
//!
//! Chunk 1 of the shim (this module) ships the entry point and the
//! `initialize` handshake. Session and prompt handlers return a structured
//! "not yet implemented" error so the daemon's supervision lifecycle can
//! discover the shim and surface a clean status without dispatching real
//! traffic. The rest lands in the next chunk.

pub mod bridge;
pub mod model_catalog;
pub mod session;
pub mod tool_translator;

pub use bridge::run_stdio;
