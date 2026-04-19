//! Tool registry abstraction.
//!
//! A `Tool` contributes its name, description, JSON Schema for input
//! parameters, and an async handler that receives the raw `params` value and
//! returns a `ToolResult`. The registry owns a collection of boxed tools and
//! exposes list/call operations used by the MCP server.

use std::collections::HashMap;

use async_trait::async_trait;
use serde::Serialize;
use serde_json::Value;

use crate::mcp::protocol::ToolResult;

/// Outcome of a `tools/call` from a single `Tool`. Tools that cannot even
/// begin their work (missing parameters, invalid types) should return
/// `Err(ToolError)`, which the dispatcher turns into a JSON-RPC error.
/// Tool-level failures that should reach the caller as a regular
/// tool-result with `isError: true` should use `ToolResult::error(...)`.
#[derive(Debug)]
pub enum ToolError {
    InvalidParams(String),
    Internal(String),
}

impl ToolError {
    #[must_use]
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidParams(message.into())
    }

    #[must_use]
    pub fn internal(message: impl Into<String>) -> Self {
        Self::Internal(message.into())
    }

    #[must_use]
    pub fn message(&self) -> &str {
        match self {
            Self::InvalidParams(message) | Self::Internal(message) => message,
        }
    }
}

/// Contract for a single MCP tool.
#[async_trait]
pub trait Tool: Send + Sync {
    fn name(&self) -> &'static str;
    fn description(&self) -> &'static str;
    fn input_schema(&self) -> Value;
    async fn call(&self, params: Value) -> Result<ToolResult, ToolError>;
}

/// Serialized metadata returned in a `tools/list` response. Mirrors the MCP
/// spec's `Tool` shape.
#[derive(Debug, Clone, Serialize)]
pub struct ToolMetadata {
    pub name: &'static str,
    pub description: &'static str,
    #[serde(rename = "inputSchema")]
    pub input_schema: Value,
}

/// Owns the set of tools available on a server.
pub struct ToolRegistry {
    tools: HashMap<&'static str, Box<dyn Tool>>,
    order: Vec<&'static str>,
}

impl Default for ToolRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl ToolRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self {
            tools: HashMap::new(),
            order: Vec::new(),
        }
    }

    pub fn register(&mut self, tool: Box<dyn Tool>) {
        let name = tool.name();
        self.order.push(name);
        self.tools.insert(name, tool);
    }

    #[must_use]
    pub fn metadata(&self) -> Vec<ToolMetadata> {
        self.order
            .iter()
            .filter_map(|name| self.tools.get(name))
            .map(|tool| ToolMetadata {
                name: tool.name(),
                description: tool.description(),
                input_schema: tool.input_schema(),
            })
            .collect()
    }

    #[must_use]
    pub fn get(&self, name: &str) -> Option<&dyn Tool> {
        self.tools.get(name).map(AsRef::as_ref)
    }
}
