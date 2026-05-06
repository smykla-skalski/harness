use super::*;
use std::process::Command;
use std::sync::{Arc, Mutex, OnceLock};

use agent_client_protocol::Channel;
use agent_client_protocol::schema::{
    AgentCapabilities, ContentChunk, InitializeResponse, NewSessionResponse, PromptResponse,
    SessionUpdate, StopReason,
};
use tokio::sync::broadcast;

use crate::agents::acp::supervision::{SupervisionConfig, WatchdogState};
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::db::DaemonDb;
use crate::daemon::index::DiscoveredProject;
use crate::session::service as session_service;
use crate::session::types::{ManagedAgentRef, SessionRole};

#[track_caller]
fn ok<T, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> T {
    assert!(
        result.is_ok(),
        "{context}: unexpected Err({:?})",
        result.as_ref().err()
    );
    let Ok(value) = result else {
        unreachable!("{context}");
    };
    value
}

#[track_caller]
fn some<T>(value: Option<T>, context: &str) -> T {
    assert!(value.is_some(), "{context}: unexpected None");
    let Some(value) = value else {
        unreachable!("{context}");
    };
    value
}

fn protocol_manager(runtime_name: &str, acp_id: &str, session_id: &str) -> AcpAgentManagerHandle {
    let (sender, _) = broadcast::channel(8);
    let db = ok(DaemonDb::open_in_memory(), "open db");
    let project = DiscoveredProject {
        project_id: "project-protocol".into(),
        name: "harness".into(),
        project_dir: Some("/tmp/harness".into()),
        repository_root: Some("/tmp/harness".into()),
        checkout_id: "checkout-protocol".into(),
        checkout_name: "Repository".into(),
        context_root: "/tmp/data/projects/project-protocol".into(),
        is_worktree: false,
        worktree_name: None,
    };
    ok(db.sync_project(&project), "sync project");
    let now = "2026-04-30T12:00:00Z";
    let mut state =
        session_service::build_new_session("protocol", "protocol", session_id, "claude", None, now);
    ok(
        session_service::apply_join_session(
            &mut state,
            "Protocol ACP",
            runtime_name,
            SessionRole::Worker,
            &[],
            None,
            now,
            None,
            Some(ManagedAgentRef::acp(acp_id)),
        ),
        "register ACP agent",
    );
    ok(db.sync_session(&project.project_id, &state), "sync session");
    let db = Arc::new(Mutex::new(db));
    let db_slot = Arc::new(OnceLock::new());
    assert!(
        db_slot.set(Arc::clone(&db)).is_ok(),
        "seed protocol test db"
    );
    AcpAgentManagerHandle::new(sender, db_slot)
}

#[tokio::test]
#[cfg(unix)]
async fn prompt_turn_against_sdk_cookbook_style_agent_streams_events() {
    let project = ok(tempfile::tempdir(), "project tempdir");
    let mut supervisor_child = ok(
        Command::new("sleep").arg("60").spawn(),
        "spawn supervisor child",
    );
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
    let (_command_tx, command_rx) = mpsc::unbounded_channel();
    let project_dir = project.path().to_path_buf();
    let protocol_supervisor = Arc::clone(&supervisor);
    let manager = protocol_manager(
        "fake",
        "agent-acp-1",
        "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e",
    );

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
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: Some("smoke the second descriptor".to_string()),
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                    runtime_name: "fake".to_string(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard: Arc::new(SessionRouteGuard::default()),
                    manager,
                })
                .await
            })
            .await
    });

    let notification = ok(
        tokio::time::timeout(Duration::from_secs(2), notifications.recv()).await,
        "prompt turn should stream an event",
    );
    let notification = some(notification, "notification channel should stay open");
    match notification.update {
        SessionUpdate::AgentMessageChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => assert_eq!(text.text, "second ACP descriptor smoke"),
            other => unreachable!("expected text content, got {:?}", other),
        },
        other => unreachable!("expected agent message chunk, got {:?}", other),
    }
    assert_ne!(supervisor.watchdog_state(), WatchdogState::Fired);

    assert!(cancel_tx.send(()).is_ok());
    let protocol_result = ok(
        ok(
            tokio::time::timeout(Duration::from_secs(2), protocol_task).await,
            "protocol should stop after cancel",
        ),
        "protocol task should not panic",
    );
    ok(protocol_result, "protocol should complete cleanly");

    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}

#[tokio::test]
#[cfg(unix)]
async fn protocol_rejects_notification_with_unknown_session_id() {
    let project = ok(tempfile::tempdir(), "project tempdir");
    let mut supervisor_child = ok(
        Command::new("sleep").arg("60").spawn(),
        "spawn supervisor child",
    );
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
    let (_command_tx, command_rx) = mpsc::unbounded_channel();
    let project_dir = project.path().to_path_buf();
    let protocol_supervisor = Arc::clone(&supervisor);
    let manager = protocol_manager(
        "fake",
        "agent-acp-1",
        "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e",
    );

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
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: Some("trigger stale session".to_string()),
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                    runtime_name: "fake".to_string(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard: Arc::new(SessionRouteGuard::default()),
                    manager,
                })
                .await
            })
            .await
    });

    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(cancel_tx.send(()).is_ok());
    let protocol_result = ok(
        ok(
            tokio::time::timeout(Duration::from_secs(2), protocol_task).await,
            "protocol should stop after cancel",
        ),
        "protocol task should not panic",
    );
    ok(
        protocol_result,
        "protocol should remain healthy after stale notification",
    );

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

async fn run_agent_with_stale_notification(
    transport: Channel,
) -> agent_client_protocol::Result<()> {
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
        runtime_helpers::disconnect_reason_from_error(&error),
        DisconnectReason::InitializeTimeout
    );
}

#[test]
fn disconnect_reason_maps_prompt_deadline() {
    let error = deadline_error("session/prompt", Duration::from_millis(25));

    assert_eq!(
        runtime_helpers::disconnect_reason_from_error(&error),
        DisconnectReason::PromptTimeout
    );
}

#[test]
fn disconnect_reason_keeps_non_transport_internal_errors_as_stdio_closed() {
    let error = AcpError::new(-32603, "session/prompt internal failure");

    assert_eq!(
        runtime_helpers::disconnect_reason_from_error(&error),
        DisconnectReason::StdioClosed
    );
}

#[test]
fn disconnect_reason_maps_transport_closed_errors() {
    let error = AcpError::new(-32603, "transport connection closed");

    assert_eq!(
        runtime_helpers::disconnect_reason_from_error(&error),
        DisconnectReason::TransportClosed
    );
}

mod route_guard_tests;
