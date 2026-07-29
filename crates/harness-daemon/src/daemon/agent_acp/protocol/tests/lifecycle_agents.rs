//! Mock agents for the session-lifecycle wire tests.
//!
//! Kept apart from `agents.rs` only to stay under the source-size cap; these
//! record what a lifecycle request actually carried so a test can assert the
//! agent saw it, rather than asserting on the request we built.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, CloseSessionRequest, ContentBlock, ContentChunk,
    InitializeRequest, InitializeResponse, LoadSessionRequest, LoadSessionResponse, McpServer,
    NewSessionRequest, NewSessionResponse, ResumeSessionRequest, ResumeSessionResponse,
    SessionAdditionalDirectoriesCapabilities, SessionCapabilities, SessionCloseCapabilities,
    SessionNotification, SessionResumeCapabilities, SessionUpdate, TextContent,
};
use agent_client_protocol::{Agent, Channel};

/// Records the MCP servers and extra roots that arrived on `session/new`.
///
/// Advertises `additionalDirectories` so the capability gate lets the roots
/// through; MCP stdio needs no capability.
pub(super) async fn run_agent_recording_session_inputs(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    Agent
        .builder()
        .name("session-inputs-agent")
        .on_receive_request(
            async move |initialize: InitializeRequest, responder, _connection| {
                responder.respond(
                    InitializeResponse::new(initialize.protocol_version).agent_capabilities(
                        AgentCapabilities::new().session_capabilities(
                            SessionCapabilities::new().additional_directories(
                                SessionAdditionalDirectoriesCapabilities::new(),
                            ),
                        ),
                    ),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: NewSessionRequest, responder, _connection| {
                operations
                    .lock()
                    .expect("record new session")
                    .push(session_inputs_record(
                        "new",
                        &request.mcp_servers,
                        &request.additional_directories,
                    ));
                responder.respond(NewSessionResponse::new("acp-session-1"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_to(transport)
        .await
}

/// Records whether the client opened the session with `session/resume` or
/// `session/new`, and what inputs each carried.
pub(super) async fn run_agent_recording_session_resume(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    let new_operations = Arc::clone(&operations);
    Agent
        .builder()
        .name("session-resume-agent")
        .on_receive_request(
            async move |initialize: InitializeRequest, responder, _connection| {
                responder.respond(
                    InitializeResponse::new(initialize.protocol_version).agent_capabilities(
                        AgentCapabilities::new().session_capabilities(
                            SessionCapabilities::new().resume(SessionResumeCapabilities::new()),
                        ),
                    ),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: NewSessionRequest, responder, _connection| {
                new_operations
                    .lock()
                    .expect("record new")
                    .push(session_inputs_record(
                        "new",
                        &request.mcp_servers,
                        &request.additional_directories,
                    ));
                responder.respond(NewSessionResponse::new("acp-session-fresh"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: ResumeSessionRequest, responder, _connection| {
                operations.lock().expect("record resume").push(format!(
                    "resume:{}:{}",
                    request.session_id.0,
                    session_inputs_record(
                        "inputs",
                        &request.mcp_servers,
                        &request.additional_directories
                    )
                ));
                responder.respond(ResumeSessionResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_to(transport)
        .await
}

/// Accepts `session/close` and never answers it.
///
/// Stands in for an agent that is alive on the wire but wedged: the child is
/// running, so nothing kills it, and without a deadline the command loop waits
/// on that response for as long as the process lives.
pub(super) async fn run_agent_never_answering_close(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    Agent
        .builder()
        .name("wedged-close-agent")
        .on_receive_request(
            async move |initialize: InitializeRequest, responder, _connection| {
                responder.respond(
                    InitializeResponse::new(initialize.protocol_version).agent_capabilities(
                        AgentCapabilities::new().session_capabilities(
                            SessionCapabilities::new().close(SessionCloseCapabilities::new()),
                        ),
                    ),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: NewSessionRequest, responder, _connection| {
                responder.respond(NewSessionResponse::new("acp-session-1"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: CloseSessionRequest, _responder, _connection| {
                operations
                    .lock()
                    .expect("record close")
                    .push(format!("close:{}", request.session_id.0));
                std::future::pending::<()>().await;
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_to(transport)
        .await
}

/// Advertises both `resume` and `loadSession`, and records which one the
/// client chose. Resume restores the same context without a replay, so a
/// client offered both must reach for it, never for load.
pub(super) async fn run_agent_advertising_resume_and_load(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    let load_operations = Arc::clone(&operations);
    Agent
        .builder()
        .name("resume-and-load-agent")
        .on_receive_request(
            async move |initialize: InitializeRequest, responder, _connection| {
                responder.respond(
                    InitializeResponse::new(initialize.protocol_version).agent_capabilities(
                        AgentCapabilities::new()
                            .load_session(true)
                            .session_capabilities(
                                SessionCapabilities::new().resume(SessionResumeCapabilities::new()),
                            ),
                    ),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: ResumeSessionRequest, responder, _connection| {
                operations
                    .lock()
                    .expect("record resume")
                    .push(format!("resume:{}", request.session_id.0));
                responder.respond(ResumeSessionResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: LoadSessionRequest, responder, _connection| {
                load_operations
                    .lock()
                    .expect("record load")
                    .push(format!("load:{}", request.session_id.0));
                responder.respond(LoadSessionResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_to(transport)
        .await
}

/// Loads a session the way protocol v1 specifies: the whole conversation is
/// replayed as `session/update` notifications before the response.
///
/// Advertises `loadSession` but not `resume`, so a start with a stored id has
/// only this route to take.
pub(super) async fn run_agent_replaying_session_load(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    let new_operations = Arc::clone(&operations);
    Agent
        .builder()
        .name("session-load-agent")
        .on_receive_request(
            async move |initialize: InitializeRequest, responder, _connection| {
                responder.respond(
                    InitializeResponse::new(initialize.protocol_version).agent_capabilities(
                        AgentCapabilities::new()
                            .load_session(true)
                            .session_capabilities(
                                SessionCapabilities::new().additional_directories(
                                    SessionAdditionalDirectoriesCapabilities::new(),
                                ),
                            ),
                    ),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: NewSessionRequest, responder, _connection| {
                new_operations
                    .lock()
                    .expect("record new")
                    .push(session_inputs_record(
                        "new",
                        &request.mcp_servers,
                        &request.additional_directories,
                    ));
                responder.respond(NewSessionResponse::new("acp-session-fresh"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: LoadSessionRequest, responder, connection| {
                operations.lock().expect("record load").push(format!(
                    "load:{}:{}",
                    request.session_id.0,
                    session_inputs_record(
                        "inputs",
                        &request.mcp_servers,
                        &request.additional_directories
                    )
                ));
                for turn in ["replayed user turn", "replayed agent turn"] {
                    connection.send_notification(SessionNotification::new(
                        request.session_id.clone(),
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new(turn),
                        ))),
                    ))?;
                }
                responder.respond(LoadSessionResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_to(transport)
        .await
}

/// Advertises `loadSession` and then refuses the load.
///
/// Stands in for an agent that has since dropped the stored session, which the
/// start has to survive by opening a fresh one.
pub(super) async fn run_agent_refusing_session_load(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    let new_operations = Arc::clone(&operations);
    Agent
        .builder()
        .name("session-load-refusing-agent")
        .on_receive_request(
            async move |initialize: InitializeRequest, responder, _connection| {
                responder.respond(
                    InitializeResponse::new(initialize.protocol_version)
                        .agent_capabilities(AgentCapabilities::new().load_session(true)),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: NewSessionRequest, responder, _connection| {
                new_operations
                    .lock()
                    .expect("record new")
                    .push(session_inputs_record(
                        "new",
                        &request.mcp_servers,
                        &request.additional_directories,
                    ));
                responder.respond(NewSessionResponse::new("acp-session-fresh"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: LoadSessionRequest,
                        responder: agent_client_protocol::Responder<LoadSessionResponse>,
                        _connection| {
                operations
                    .lock()
                    .expect("record load")
                    .push(format!("load-refused:{}", request.session_id.0));
                responder.respond_with_error(agent_client_protocol::Error::new(
                    -32602,
                    "no such session".to_string(),
                ))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_to(transport)
        .await
}

fn session_inputs_record(
    method: &str,
    mcp_servers: &[McpServer],
    additional_directories: &[PathBuf],
) -> String {
    let servers = mcp_servers
        .iter()
        .map(server_name)
        .collect::<Vec<_>>()
        .join(",");
    let directories = additional_directories
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join(",");
    format!("{method}:mcp={servers}:dirs={directories}")
}

fn server_name(server: &McpServer) -> String {
    match server {
        McpServer::Stdio(stdio) => stdio.name.clone(),
        McpServer::Http(http) => http.name.clone(),
        McpServer::Sse(sse) => sse.name.clone(),
        // The SDK enum is non_exhaustive; an unnamed transport still fails the
        // assertion rather than silently reading as an expected server.
        _ => "unknown-transport".to_string(),
    }
}
