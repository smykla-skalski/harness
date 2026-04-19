//! MCP JSON-RPC 2.0 message types and framing helpers.
//!
//! MCP rides on JSON-RPC 2.0: every request carries `jsonrpc: "2.0"`, a
//! numeric or string `id`, a `method` name, and a `params` object. Responses
//! echo the request `id` and carry either `result` or `error`. Notifications
//! omit the `id` field entirely.

mod error;
mod message;
mod tool_result;

#[cfg(test)]
mod tests;

pub use error::{ErrorCode, ErrorObject};
pub use message::{JsonRpcVersion, Notification, Request, RequestId, Response};
pub use tool_result::{ContentBlock, ToolResult};
