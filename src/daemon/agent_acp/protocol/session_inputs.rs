//! Build the `session/new` request from descriptor-declared session inputs.
//!
//! Both extras are optional in protocol v1 and an agent that never advertised
//! them may reject the whole request, so a descriptor lists what it wants
//! unconditionally and this module drops whatever the agent cannot accept.

use std::path::PathBuf;

use agent_client_protocol::schema::v1::{
    EnvVariable, HttpHeader, LoadSessionRequest, McpServer, McpServerHttp, McpServerSse,
    McpServerStdio, NewSessionRequest, ResumeSessionRequest, SessionId,
};

use super::session_config::AcpSessionRequestConfig;
use crate::daemon::agent_acp::{AcpAgentHandshake, AcpMcpServer};

/// The inputs both `session/new` and `session/resume` carry, after the
/// capability gate has dropped whatever this agent cannot accept.
struct SessionInputs {
    additional_directories: Vec<PathBuf>,
    mcp_servers: Vec<McpServer>,
}

fn session_inputs(
    config: &AcpSessionRequestConfig,
    handshake: Option<&AcpAgentHandshake>,
) -> SessionInputs {
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
    SessionInputs {
        additional_directories,
        mcp_servers: config
            .mcp_servers()
            .iter()
            .filter(|server| agent_accepts(server, handshake))
            .map(mcp_server)
            .collect(),
    }
}

pub(super) fn new_session_request(
    cwd: PathBuf,
    config: &AcpSessionRequestConfig,
    handshake: Option<&AcpAgentHandshake>,
) -> NewSessionRequest {
    let inputs = session_inputs(config, handshake);
    NewSessionRequest::new(cwd)
        .additional_directories(inputs.additional_directories)
        .mcp_servers(inputs.mcp_servers)
}

/// Resume carries the same inputs as a new session: the agent needs its MCP
/// servers and roots again, whether the conversation is fresh or not.
pub(super) fn resume_session_request(
    session_id: SessionId,
    cwd: PathBuf,
    config: &AcpSessionRequestConfig,
    handshake: Option<&AcpAgentHandshake>,
) -> ResumeSessionRequest {
    let inputs = session_inputs(config, handshake);
    ResumeSessionRequest::new(session_id, cwd)
        .additional_directories(inputs.additional_directories)
        .mcp_servers(inputs.mcp_servers)
}

/// Load carries the same inputs as resume; the two differ only in whether the
/// agent replays the conversation back to us before answering.
pub(super) fn load_session_request(
    session_id: SessionId,
    cwd: PathBuf,
    config: &AcpSessionRequestConfig,
    handshake: Option<&AcpAgentHandshake>,
) -> LoadSessionRequest {
    let inputs = session_inputs(config, handshake);
    LoadSessionRequest::new(session_id, cwd)
        .additional_directories(inputs.additional_directories)
        .mcp_servers(inputs.mcp_servers)
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
