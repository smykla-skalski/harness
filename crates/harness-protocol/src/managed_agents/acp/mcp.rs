//! MCP servers a descriptor or a start request offers to an agent, and the
//! redaction that keeps their credentials off client-facing surfaces.

use std::fmt;

use serde::{Deserialize, Serialize};

/// One MCP server a descriptor offers to its agent.
///
/// Mirrors the ACP `McpServer` shape without depending on the SDK, so the
/// catalog and daemon wire format stay independent of the protocol crate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "transport", rename_all = "snake_case")]
pub enum AcpMcpServer {
    Stdio {
        name: String,
        command: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        args: Vec<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        env: Vec<AcpMcpEnvVariable>,
    },
    Http {
        name: String,
        url: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        headers: Vec<AcpMcpHttpHeader>,
    },
    Sse {
        name: String,
        url: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        headers: Vec<AcpMcpHttpHeader>,
    },
}

impl AcpMcpServer {
    /// The server with secrets blanked, for publishing to clients.
    ///
    /// Redaction belongs to the boundary, not the value: descriptors publish
    /// outbound and must hide credentials, start requests carry credentials
    /// the agent needs. Marking the fields `skip_serializing` covered the
    /// first and silently emptied the second.
    ///
    /// Returns `Self` so a new variant or field must be handled here to
    /// compile, and the redacted form cannot fall behind.
    #[must_use]
    pub fn redacted(&self) -> Self {
        match self {
            Self::Stdio {
                name,
                command,
                args,
                env,
            } => Self::Stdio {
                name: name.clone(),
                command: command.clone(),
                args: args.clone(),
                env: env
                    .iter()
                    .map(|variable| AcpMcpEnvVariable {
                        name: variable.name.clone(),
                        value: String::new(),
                    })
                    .collect(),
            },
            Self::Http { name, url, headers } => Self::Http {
                name: name.clone(),
                url: url.clone(),
                headers: redacted_headers(headers),
            },
            Self::Sse { name, url, headers } => Self::Sse {
                name: name.clone(),
                url: url.clone(),
                headers: redacted_headers(headers),
            },
        }
    }

    #[must_use]
    pub fn name(&self) -> &str {
        match self {
            Self::Stdio { name, .. } | Self::Http { name, .. } | Self::Sse { name, .. } => name,
        }
    }
}

fn redacted_headers(headers: &[AcpMcpHttpHeader]) -> Vec<AcpMcpHttpHeader> {
    headers
        .iter()
        .map(|header| AcpMcpHttpHeader {
            name: header.name.clone(),
            value: String::new(),
        })
        .collect()
}

/// Every descriptor-declared server reaches clients through this one field,
/// so redacting here covers the websocket push and every descriptor response.
pub(super) fn serialize_mcp_servers_redacted<S>(
    servers: &[AcpMcpServer],
    serializer: S,
) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    servers
        .iter()
        .map(AcpMcpServer::redacted)
        .collect::<Vec<_>>()
        .serialize(serializer)
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AcpMcpEnvVariable {
    pub name: String,
    #[serde(default)]
    pub value: String,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AcpMcpHttpHeader {
    pub name: String,
    #[serde(default)]
    pub value: String,
}

/// Redacted so a `tracing` line or a panic message cannot spill the secret,
/// matching the hand-written `Debug` on `BridgeAcpStartRequest`.
impl fmt::Debug for AcpMcpEnvVariable {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AcpMcpEnvVariable")
            .field("name", &self.name)
            .field("value", &"[REDACTED]")
            .finish()
    }
}

impl fmt::Debug for AcpMcpHttpHeader {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AcpMcpHttpHeader")
            .field("name", &self.name)
            .field("value", &"[REDACTED]")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::{AcpMcpEnvVariable, AcpMcpHttpHeader, AcpMcpServer};
    use crate::managed_agents::acp::AcpSessionConfiguration;

    fn servers_with_secrets() -> Vec<AcpMcpServer> {
        vec![
            AcpMcpServer::Http {
                name: "remote".into(),
                url: "https://example.test/mcp".into(),
                headers: vec![AcpMcpHttpHeader {
                    name: "Authorization".into(),
                    value: "Bearer descriptor-secret".into(),
                }],
            },
            AcpMcpServer::Stdio {
                name: "local".into(),
                command: "/usr/bin/mcp".into(),
                args: vec!["--serve".into()],
                env: vec![AcpMcpEnvVariable {
                    name: "TOKEN".into(),
                    value: "descriptor-secret".into(),
                }],
            },
        ]
    }

    /// Descriptors reach every websocket client, remote ones included.
    #[test]
    fn session_configuration_publishes_mcp_servers_without_credentials() {
        let configuration = AcpSessionConfiguration {
            mcp_servers: servers_with_secrets(),
            ..AcpSessionConfiguration::default()
        };

        let encoded = serde_json::to_string(&configuration).expect("serialize configuration");

        assert!(
            !encoded.contains("descriptor-secret"),
            "no credential may be published; got {encoded}"
        );
        assert!(
            encoded.contains("Authorization") && encoded.contains("TOKEN"),
            "names stay visible so a client can still show what is configured"
        );
        assert!(
            encoded.contains("https://example.test/mcp") && encoded.contains("--serve"),
            "everything that is not a credential survives"
        );
    }

    /// Logs and panics leak in both directions, so `Debug` always redacts.
    #[test]
    fn mcp_secrets_stay_out_of_debug_output() {
        let debugged = format!("{:?}", servers_with_secrets());

        assert!(
            !debugged.contains("descriptor-secret"),
            "Debug must redact credentials; got {debugged}"
        );
    }
}
