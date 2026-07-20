//! Build the `session/new` request from descriptor-declared session inputs.
//!
//! Both extras are optional in protocol v1 and an agent that never advertised
//! them may reject the whole request, so a descriptor lists what it wants
//! unconditionally and this module drops whatever the agent cannot accept.

use std::path::PathBuf;

use agent_client_protocol::schema::v1::{
    EnvVariable, HttpHeader, McpServer, McpServerHttp, McpServerSse, McpServerStdio,
    NewSessionRequest,
};

use super::session_config::AcpSessionRequestConfig;
use crate::daemon::agent_acp::{AcpAgentHandshake, AcpMcpServer};

pub(super) fn new_session_request(
    cwd: PathBuf,
    config: &AcpSessionRequestConfig,
    handshake: Option<&AcpAgentHandshake>,
) -> NewSessionRequest {
    let additional_directories = if handshake.is_some_and(|handshake| {
        handshake.supports_additional_directories
    }) {
        config
            .additional_directories()
            .iter()
            .map(PathBuf::from)
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let mcp_servers = config
        .mcp_servers()
        .iter()
        .filter(|server| agent_accepts(server, handshake))
        .map(mcp_server)
        .collect::<Vec<_>>();
    NewSessionRequest::new(cwd)
        .additional_directories(additional_directories)
        .mcp_servers(mcp_servers)
}

/// Stdio servers are baseline in protocol v1; the networked transports each
/// need their own advertised capability.
fn agent_accepts(server: &AcpMcpServer, handshake: Option<&AcpAgentHandshake>) -> bool {
    match server {
        AcpMcpServer::Stdio { .. } => true,
        AcpMcpServer::Http { .. } => handshake.is_some_and(|handshake| handshake.supports_mcp_http),
        AcpMcpServer::Sse { .. } => handshake.is_some_and(|handshake| handshake.supports_mcp_sse),
    }
}

fn mcp_server(server: &AcpMcpServer) -> McpServer {
    match server {
        AcpMcpServer::Stdio {
            name,
            command,
            args,
            env,
        } => McpServer::Stdio(
            McpServerStdio::new(name.clone(), PathBuf::from(command))
                .args(args.clone())
                .env(
                    env.iter()
                        .map(|variable| {
                            EnvVariable::new(variable.name.clone(), variable.value.clone())
                        })
                        .collect::<Vec<_>>(),
                ),
        ),
        AcpMcpServer::Http { name, url, headers } => McpServer::Http(
            McpServerHttp::new(name.clone(), url.clone()).headers(http_headers(headers)),
        ),
        AcpMcpServer::Sse { name, url, headers } => McpServer::Sse(
            McpServerSse::new(name.clone(), url.clone()).headers(http_headers(headers)),
        ),
    }
}

fn http_headers(headers: &[crate::daemon::agent_acp::AcpMcpHttpHeader]) -> Vec<HttpHeader> {
    headers
        .iter()
        .map(|header| HttpHeader::new(header.name.clone(), header.value.clone()))
        .collect()
}

#[cfg(test)]
mod tests;
