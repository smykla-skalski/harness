//! MCP initialize request handling.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// MCP protocol version this server speaks. MCP allows version negotiation;
/// we echo back the latest we implement. See
/// <https://modelcontextprotocol.io/specification/2025-11-25/>.
pub const PROTOCOL_VERSION: &str = "2025-11-25";

/// Server name advertised via `initialize`.
pub const SERVER_NAME: &str = "harness-monitor-mcp";

/// Server version advertised via `initialize`; matches the crate version.
pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, Deserialize)]
pub struct InitializeParams {
    #[serde(rename = "protocolVersion", default)]
    pub protocol_version: Option<String>,
    #[serde(rename = "clientInfo", default)]
    pub client_info: Option<ClientInfo>,
    #[serde(default)]
    pub capabilities: Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClientInfo {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct InitializeResult {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: &'static str,
    pub capabilities: Value,
    #[serde(rename = "serverInfo")]
    pub server_info: ServerInfo,
}

#[derive(Debug, Clone, Serialize)]
pub struct ServerInfo {
    pub name: &'static str,
    pub version: &'static str,
}

impl InitializeResult {
    #[must_use]
    pub fn default_with_tools() -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            capabilities: json!({ "tools": {} }),
            server_info: ServerInfo {
                name: SERVER_NAME,
                version: SERVER_VERSION,
            },
        }
    }
}
