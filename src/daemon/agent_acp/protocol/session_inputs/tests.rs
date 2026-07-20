use super::*;
use crate::agents::acp::catalog::{AcpAgentDescriptor, AcpSessionConfiguration, DoctorProbe};
use crate::daemon::agent_acp::manager::AcpAgentStartRequest;
use crate::daemon::agent_acp::{AcpMcpEnvVariable, AcpMcpHttpHeader};

fn descriptor_with_inputs(
    mcp_servers: Vec<AcpMcpServer>,
    additional_directories: Vec<String>,
) -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: "fake".to_owned(),
        display_name: "Fake".to_owned(),
        capabilities: Vec::new(),
        launch_command: "fake".to_owned(),
        launch_args: Vec::new(),
        env_passthrough: Vec::new(),
        spawn_configuration: Default::default(),
        model_catalog: None,
        install_hint: None,
        session_configuration: AcpSessionConfiguration {
            mcp_servers,
            additional_directories,
            ..Default::default()
        },
        doctor_probe: DoctorProbe {
            command: "fake".to_owned(),
            args: Vec::new(),
        },
        prompt_timeout_seconds: None,
        excluded_from_initial_default: false,
        bundled_with_harness: false,
    }
}

fn config(
    mcp_servers: Vec<AcpMcpServer>,
    additional_directories: Vec<String>,
) -> AcpSessionRequestConfig {
    let descriptor = descriptor_with_inputs(mcp_servers, additional_directories);
    AcpSessionRequestConfig::from_request(&AcpAgentStartRequest::default(), &descriptor)
}

fn handshake(http: bool, sse: bool, additional_directories: bool) -> AcpAgentHandshake {
    AcpAgentHandshake {
        supports_mcp_http: http,
        supports_mcp_sse: sse,
        supports_additional_directories: additional_directories,
        ..AcpAgentHandshake::default()
    }
}

fn stdio_server() -> AcpMcpServer {
    AcpMcpServer::Stdio {
        name: "local".to_owned(),
        command: "/usr/bin/mcp".to_owned(),
        args: vec!["--serve".to_owned()],
        env: Vec::new(),
    }
}

fn http_server() -> AcpMcpServer {
    AcpMcpServer::Http {
        name: "remote".to_owned(),
        url: "https://example.test/mcp".to_owned(),
        headers: vec![AcpMcpHttpHeader {
            name: "Authorization".to_owned(),
            value: "Bearer token".to_owned(),
        }],
    }
}

fn sse_server() -> AcpMcpServer {
    AcpMcpServer::Sse {
        name: "events".to_owned(),
        url: "https://example.test/sse".to_owned(),
        headers: Vec::new(),
    }
}

fn server_names(request: &NewSessionRequest) -> Vec<String> {
    request
        .mcp_servers
        .iter()
        .map(|server| match server {
            McpServer::Stdio(stdio) => stdio.name.clone(),
            McpServer::Http(http) => http.name.clone(),
            McpServer::Sse(sse) => sse.name.clone(),
            other => unreachable!("unexpected MCP transport: {other:?}"),
        })
        .collect()
}

#[test]
fn stdio_servers_need_no_capability() {
    let request = new_session_request(
        PathBuf::from("/work"),
        &config(vec![stdio_server()], Vec::new()),
        Some(&handshake(false, false, false)),
    );

    assert_eq!(server_names(&request), vec!["local".to_string()]);
}

#[test]
fn http_and_sse_servers_are_dropped_without_the_matching_capability() {
    let request = new_session_request(
        PathBuf::from("/work"),
        &config(
            vec![stdio_server(), http_server(), sse_server()],
            Vec::new(),
        ),
        Some(&handshake(false, false, false)),
    );

    assert_eq!(
        server_names(&request),
        vec!["local".to_string()],
        "only the stdio server should survive"
    );
}

#[test]
fn http_server_survives_when_the_agent_advertises_http() {
    let request = new_session_request(
        PathBuf::from("/work"),
        &config(vec![http_server(), sse_server()], Vec::new()),
        Some(&handshake(true, false, false)),
    );

    assert_eq!(server_names(&request), vec!["remote".to_string()]);
}

#[test]
fn sse_server_survives_when_the_agent_advertises_sse() {
    let request = new_session_request(
        PathBuf::from("/work"),
        &config(vec![http_server(), sse_server()], Vec::new()),
        Some(&handshake(false, true, false)),
    );

    assert_eq!(server_names(&request), vec!["events".to_string()]);
}

#[test]
fn additional_directories_are_dropped_without_the_capability() {
    let request = new_session_request(
        PathBuf::from("/work"),
        &config(Vec::new(), vec!["/extra".to_owned()]),
        Some(&handshake(false, false, false)),
    );

    assert!(
        request.additional_directories.is_empty(),
        "agent did not advertise additionalDirectories"
    );
}

#[test]
fn additional_directories_are_sent_when_advertised() {
    let request = new_session_request(
        PathBuf::from("/work"),
        &config(Vec::new(), vec!["/extra".to_owned()]),
        Some(&handshake(false, false, true)),
    );

    assert_eq!(request.additional_directories, vec![PathBuf::from("/extra")]);
}

#[test]
fn a_missing_handshake_drops_every_optional_input() {
    let request = new_session_request(
        PathBuf::from("/work"),
        &config(
            vec![stdio_server(), http_server()],
            vec!["/extra".to_owned()],
        ),
        None,
    );

    assert_eq!(request.cwd, PathBuf::from("/work"));
    assert_eq!(
        server_names(&request),
        vec!["local".to_string()],
        "stdio needs no capability, http does"
    );
    assert!(request.additional_directories.is_empty());
}

#[test]
fn stdio_server_carries_args_and_environment() {
    let request = new_session_request(
        PathBuf::from("/work"),
        &config(
            vec![AcpMcpServer::Stdio {
                name: "local".to_owned(),
                command: "/usr/bin/mcp".to_owned(),
                args: vec!["--serve".to_owned()],
                env: vec![AcpMcpEnvVariable {
                    name: "TOKEN".to_owned(),
                    value: "secret".to_owned(),
                }],
            }],
            Vec::new(),
        ),
        Some(&handshake(false, false, false)),
    );

    let McpServer::Stdio(stdio) = &request.mcp_servers[0] else {
        unreachable!("stdio server must round-trip as stdio");
    };
    assert_eq!(stdio.command, PathBuf::from("/usr/bin/mcp"));
    assert_eq!(stdio.args, vec!["--serve".to_string()]);
    assert_eq!(stdio.env.len(), 1);
    assert_eq!(stdio.env[0].name, "TOKEN");
    assert_eq!(stdio.env[0].value, "secret");
}
