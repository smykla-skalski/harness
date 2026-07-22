//! A real HTTP round-trip: the harness client, driven over `AcpTransport::Http`,
//! completes initialize, new-session, and prompt against an in-process
//! `AcpHttpServer` mock agent. No network, so no flakiness.

use std::sync::Arc;
use std::time::Duration;

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, ContentBlock, ContentChunk, InitializeRequest,
    InitializeResponse, NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse,
    SessionId, SessionNotification, SessionUpdate, StopReason, TextContent,
};
use agent_client_protocol::{Agent, Client, ConnectTo, ConnectionTo};
use agent_client_protocol_http::{AcpHttpServer, HttpClient};
use tokio::net::TcpListener;
use tokio::sync::{broadcast, mpsc};

use super::super::AcpTransport;
use super::super::context::ProtocolContext;
use super::super::handlers::ClientHandlers;
use super::super::session_guard::SessionRouteGuard;
use super::{ok, protocol_manager};
use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::acp::supervision::{AcpSessionSupervisor, SupervisedProcess, SupervisionConfig};
use crate::daemon::agent_acp::permission_bridge::PermissionBridgeHandle;
use crate::hooks::runner_policy::managed_cluster_binaries;

/// The agent side served by the HTTP server. Rebuilt per connection, so it
/// holds no state and captures nothing.
fn mock_remote_agent() -> impl ConnectTo<Client> {
    Agent
        .builder()
        .name("remote-mock-agent")
        .on_receive_request(
            async move |initialize: InitializeRequest, responder, _connection| {
                responder.respond(
                    InitializeResponse::new(initialize.protocol_version)
                        .agent_capabilities(AgentCapabilities::new()),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: NewSessionRequest, responder, _connection| {
                responder.respond(NewSessionResponse::new("remote-session"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: PromptRequest, responder, connection| {
                connection.send_notification(SessionNotification::new(
                    request.session_id,
                    SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                        TextContent::new("hello over http"),
                    ))),
                ))?;
                responder.respond(PromptResponse::new(StopReason::EndTurn))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
}

struct ClientSide {
    handlers: ClientHandlers,
    _bridge: PermissionBridgeHandle,
    project: tempfile::TempDir,
}

/// The daemon-side session id, which the manager validates as a lowercase UUID.
/// It is unrelated to the agent's own ACP session id ("remote-session").
const DAEMON_SESSION: &str = "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e";
const ACP_ID: &str = "agent-acp-remote";

fn client_side() -> ClientSide {
    let project = ok(tempfile::tempdir(), "project tempdir");
    let supervisor = Arc::new(AcpSessionSupervisor::with_process(
        SupervisedProcess::remote(),
        SupervisionConfig::default(),
    ));
    let (sender, _receiver) = broadcast::channel(8);
    let bridge =
        PermissionBridgeHandle::spawn(ACP_ID.to_string(), DAEMON_SESSION.to_string(), sender);
    let client = Arc::new(HarnessAcpClient::new(
        project.path().to_path_buf(),
        project.path().to_path_buf(),
        None,
        managed_cluster_binaries(),
        bridge.mode(Duration::from_secs(30)),
    ));
    let session_guard = Arc::new(SessionRouteGuard::default());
    let (notifications, _routed) = mpsc::channel(8);
    ClientSide {
        handlers: ClientHandlers {
            context: ProtocolContext::new(
                client,
                Arc::clone(&supervisor),
                Arc::clone(&session_guard),
            ),
            session_guard,
            supervisor,
            manager: protocol_manager("remote", ACP_ID, DAEMON_SESSION),
            notifications,
        },
        _bridge: bridge,
        project,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn http_transport_completes_initialize_new_session_and_prompt() {
    let router = AcpHttpServer::new(mock_remote_agent).into_router();
    let listener = ok(TcpListener::bind("127.0.0.1:0").await, "bind listener");
    let addr = ok(listener.local_addr(), "listener addr");
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });

    let client = client_side();
    let cwd = client.project.path().to_path_buf();
    let http = ok(HttpClient::new(format!("http://{addr}")), "http client");

    let outcome = AcpTransport::Http(http)
        .connect(
            client.handlers,
            async move |connection: ConnectionTo<Agent>| {
                connection
                    .send_request(InitializeRequest::new(ProtocolVersion::V1))
                    .block_task()
                    .await?;
                let session: NewSessionResponse = connection
                    .send_request(NewSessionRequest::new(cwd))
                    .block_task()
                    .await?;
                let prompt: PromptResponse = connection
                    .send_request(PromptRequest::new(
                        session.session_id.clone(),
                        vec![ContentBlock::Text(TextContent::new("ping"))],
                    ))
                    .block_task()
                    .await?;
                Ok((session, prompt))
            },
        )
        .await;

    let (session, prompt) = ok(outcome, "http round-trip");
    assert_eq!(session.session_id, SessionId::new("remote-session"));
    assert_eq!(prompt.stop_reason, StopReason::EndTurn);

    server.abort();
}
