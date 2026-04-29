use super::*;
use std::process::Command;

use agent_client_protocol::Channel;
use agent_client_protocol::schema::{
    AgentCapabilities, ContentChunk, InitializeResponse, NewSessionResponse, PromptResponse,
    SessionUpdate, StopReason,
};

use crate::agents::acp::supervision::{SupervisionConfig, WatchdogState};

#[tokio::test]
#[cfg(unix)]
async fn prompt_turn_against_sdk_cookbook_style_agent_streams_events() {
    let project = tempfile::tempdir().expect("project tempdir");
    let mut supervisor_child = Command::new("sleep")
        .arg("60")
        .spawn()
        .expect("spawn supervisor child");
    let supervisor = Arc::new(AcpSessionSupervisor::new(
        &supervisor_child,
        SupervisionConfig {
            initialize_timeout: Duration::from_secs(1),
            prompt_timeout: Duration::from_secs(1),
            ..SupervisionConfig::default()
        },
    ));
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(run_cookbook_style_agent(agent_transport));
    let (notification_tx, mut notifications) = mpsc::channel(4);
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let project_dir = project.path().to_path_buf();
    let protocol_supervisor = Arc::clone(&supervisor);

    let protocol_task = tokio::spawn(async move {
        Client
            .builder()
            .name("harness-test")
            .on_receive_notification(
                async move |notification: SessionNotification, _connection| {
                    notification_tx
                        .send(notification)
                        .await
                        .map_err(|error| AcpError::new(-32603, format!("queue event: {error}")))?;
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .connect_with(client_transport, async move |connection| {
                run_connection(
                    connection,
                    project_dir,
                    Some("smoke the second descriptor".to_string()),
                    protocol_supervisor,
                    cancel_rx,
                    Arc::new(SessionRouteGuard::default()),
                )
                .await
            })
            .await
    });

    let notification = tokio::time::timeout(Duration::from_secs(2), notifications.recv())
        .await
        .expect("prompt turn should stream an event")
        .expect("notification channel should stay open");
    let SessionUpdate::AgentMessageChunk(chunk) = notification.update else {
        panic!("expected agent message chunk");
    };
    let ContentBlock::Text(text) = chunk.content else {
        panic!("expected text content");
    };
    assert_eq!(text.text, "second ACP descriptor smoke");
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Active);

    cancel_tx.send(()).expect("send cancel");
    let protocol_result = tokio::time::timeout(Duration::from_secs(2), protocol_task)
        .await
        .expect("protocol should stop after cancel")
        .expect("protocol task should not panic");
    protocol_result.expect("protocol should complete cleanly");

    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}

#[tokio::test]
#[cfg(unix)]
async fn protocol_rejects_notification_with_unknown_session_id() {
    let project = tempfile::tempdir().expect("project tempdir");
    let mut supervisor_child = Command::new("sleep")
        .arg("60")
        .spawn()
        .expect("spawn supervisor child");
    let supervisor = Arc::new(AcpSessionSupervisor::new(
        &supervisor_child,
        SupervisionConfig {
            initialize_timeout: Duration::from_secs(1),
            prompt_timeout: Duration::from_secs(1),
            ..SupervisionConfig::default()
        },
    ));
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(run_agent_with_stale_notification(agent_transport));
    let (notification_tx, _notifications) = mpsc::channel(4);
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let project_dir = project.path().to_path_buf();
    let protocol_supervisor = Arc::clone(&supervisor);

    let protocol_task = tokio::spawn(async move {
        Client
            .builder()
            .name("harness-test")
            .on_receive_notification(
                async move |notification: SessionNotification, _connection| {
                    notification_tx
                        .send(notification)
                        .await
                        .map_err(|error| AcpError::new(-32603, format!("queue event: {error}")))?;
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .connect_with(client_transport, async move |connection| {
                run_connection(
                    connection,
                    project_dir,
                    Some("trigger stale session".to_string()),
                    protocol_supervisor,
                    cancel_rx,
                    Arc::new(SessionRouteGuard::default()),
                )
                .await
            })
            .await
    });

    tokio::time::sleep(Duration::from_millis(200)).await;
    cancel_tx.send(()).expect("send cancel");
    let protocol_result = tokio::time::timeout(Duration::from_secs(2), protocol_task)
        .await
        .expect("protocol should stop after cancel")
        .expect("protocol task should not panic");
    protocol_result.expect("protocol should remain healthy after stale notification");

    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}

async fn run_cookbook_style_agent(transport: Channel) -> agent_client_protocol::Result<()> {
    Agent
        .builder()
        .name("cookbook-style-agent")
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
                responder.respond(NewSessionResponse::new("cookbook-style-session"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: PromptRequest, responder, connection| {
                connection.send_notification(SessionNotification::new(
                    request.session_id,
                    SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                        TextContent::new("second ACP descriptor smoke"),
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
        .connect_to(transport)
        .await
}

async fn run_agent_with_stale_notification(transport: Channel) -> agent_client_protocol::Result<()> {
    Agent
        .builder()
        .name("stale-notification-agent")
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
                responder.respond(NewSessionResponse::new("acp-session-1"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: PromptRequest, responder, connection| {
                connection.send_notification(SessionNotification::new(
                    SessionId::new("acp-session-stale"),
                    SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                        TextContent::new("wrong session"),
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
        .connect_to(transport)
        .await
}

#[test]
fn disconnect_reason_maps_initialize_deadline() {
    let error = deadline_error("session/initialize", Duration::from_millis(25));

    assert_eq!(
        disconnect_reason_from_error(&error),
        DisconnectReason::InitializeTimeout
    );
}

#[test]
fn disconnect_reason_maps_prompt_deadline() {
    let error = deadline_error("session/prompt", Duration::from_millis(25));

    assert_eq!(
        disconnect_reason_from_error(&error),
        DisconnectReason::PromptTimeout
    );
}

#[test]
fn disconnect_reason_keeps_non_transport_internal_errors_as_stdio_closed() {
    let error = AcpError::new(-32603, "session/prompt internal failure");

    assert_eq!(
        disconnect_reason_from_error(&error),
        DisconnectReason::StdioClosed
    );
}

#[test]
fn disconnect_reason_maps_transport_closed_errors() {
    let error = AcpError::new(-32603, "transport connection closed");

    assert_eq!(
        disconnect_reason_from_error(&error),
        DisconnectReason::TransportClosed
    );
}

#[test]
fn session_route_guard_rejects_before_initialization() {
    let guard = SessionRouteGuard::default();
    let error = guard
        .ensure_known(&SessionId::new("acp-session-1"))
        .expect_err("guard should reject before initialization");
    assert_eq!(error.code, session_guard::ACP_STALE_SESSION_ID);
    assert!(
        error.message.contains("stale_session_id"),
        "unexpected message: {}",
        error.message
    );
}

#[test]
fn session_route_guard_rejects_stale_session_id() {
    let guard = SessionRouteGuard::default();
    guard.start_session(SessionId::new("acp-session-1"));
    let error = guard
        .ensure_known(&SessionId::new("acp-session-2"))
        .expect_err("guard should reject unknown session id");
    assert_eq!(error.code, session_guard::ACP_STALE_SESSION_ID);
    assert!(
        error.message.contains("stale_session_id"),
        "unexpected message: {}",
        error.message
    );
}

#[test]
fn session_route_guard_accepts_expected_session_id() {
    let guard = SessionRouteGuard::default();
    let session_id = SessionId::new("acp-session-1");
    guard.start_session(session_id.clone());
    guard
        .ensure_known(&session_id)
        .expect("guard should accept expected session id");
}

#[test]
fn session_route_guard_rejects_after_session_end() {
    let guard = SessionRouteGuard::default();
    let session_id = SessionId::new("acp-session-1");
    guard.start_session(session_id.clone());
    guard.stop_session(&session_id);
    let error = guard
        .ensure_known(&session_id)
        .expect_err("guard should reject removed session id");
    assert_eq!(error.code, session_guard::ACP_STALE_SESSION_ID);
    assert!(error.message.contains("already ended"));
}
