//! Wire tests for `run_connection`: initialize contract, logout, and
//! boolean session-configuration behavior against in-process fake agents.

use super::agents::{run_agent_recording_boolean_config, run_agent_recording_initialize_contract};
use super::*;

#[tokio::test]
#[cfg(unix)]
async fn run_connection_sends_client_capabilities_and_client_info() {
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
    let operations = Arc::new(Mutex::new(Vec::<String>::new()));
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(run_agent_recording_initialize_contract(
        agent_transport,
        Arc::clone(&operations),
    ));
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
            .connect_with(client_transport, async move |connection| {
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: None,
                    session_config: disabled_session_config(),
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                    runtime_name: "fake".to_string(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard: Arc::new(SessionRouteGuard::default()),
                    manager,
                    credential: None,
                })
                .await
            })
            .await
    });

    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(cancel_tx.send(()).is_ok());
    let protocol_result = ok(
        ok(
            tokio::time::timeout(Duration::from_secs(2), protocol_task).await,
            "protocol should stop after cancel",
        ),
        "protocol task should not panic",
    );
    ok(protocol_result, "protocol should complete cleanly");
    assert_eq!(
        operations.lock().expect("recorded operations").clone(),
        vec![format!(
            "initialize:read=true,write=true,terminal=true,boolean=true,client=harness@{}",
            env!("CARGO_PKG_VERSION"),
        )]
    );
    let handshake = some(
        supervisor.handshake().cloned(),
        "initialize response should be recorded on the supervisor",
    );
    assert_eq!(handshake.protocol_version, 1);
    assert_eq!(
        handshake.agent_name.as_deref(),
        Some("initialize-contract-agent")
    );
    assert_eq!(handshake.agent_version.as_deref(), Some("1.2.3"));
    assert!(handshake.supports_load_session);
    assert!(handshake.supports_logout);
    assert!(!handshake.supports_session_list);

    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}

#[tokio::test]
#[cfg(unix)]
async fn logout_command_sends_logout_when_capability_advertised() {
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
    let operations = Arc::new(Mutex::new(Vec::<String>::new()));
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(run_agent_recording_initialize_contract(
        agent_transport,
        Arc::clone(&operations),
    ));
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let (command_tx, command_rx) = mpsc::unbounded_channel();
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
            .connect_with(client_transport, async move |connection| {
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: None,
                    session_config: disabled_session_config(),
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                    runtime_name: "fake".to_string(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard: Arc::new(SessionRouteGuard::default()),
                    manager,
                    credential: None,
                })
                .await
            })
            .await
    });

    tokio::time::sleep(Duration::from_millis(100)).await;
    let (response_tx, response_rx) = std::sync::mpsc::sync_channel(1);
    assert!(
        command_tx
            .send(ProtocolCommand::Logout { response_tx })
            .is_ok()
    );
    let logout_result = ok(
        ok(
            tokio::task::spawn_blocking(move || response_rx.recv_timeout(Duration::from_secs(2)))
                .await,
            "logout recv task should not panic",
        ),
        "logout response should arrive",
    );
    ok(logout_result, "logout should succeed with the capability");
    assert!(cancel_tx.send(()).is_ok());
    let protocol_result = ok(
        ok(
            tokio::time::timeout(Duration::from_secs(2), protocol_task).await,
            "protocol should stop after cancel",
        ),
        "protocol task should not panic",
    );
    ok(protocol_result, "protocol should complete cleanly");
    assert!(
        operations
            .lock()
            .expect("recorded operations")
            .iter()
            .any(|operation| operation == "logout"),
        "agent should have received the logout request"
    );

    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}

#[tokio::test]
#[cfg(unix)]
async fn logout_command_rejected_without_capability() {
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
    let operations = Arc::new(Mutex::new(Vec::<String>::new()));
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(run_agent_recording_boolean_config(
        agent_transport,
        Arc::clone(&operations),
    ));
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let (command_tx, command_rx) = mpsc::unbounded_channel();
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
            .connect_with(client_transport, async move |connection| {
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: None,
                    session_config: disabled_session_config(),
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                    runtime_name: "fake".to_string(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard: Arc::new(SessionRouteGuard::default()),
                    manager,
                    credential: None,
                })
                .await
            })
            .await
    });

    tokio::time::sleep(Duration::from_millis(100)).await;
    let (response_tx, response_rx) = std::sync::mpsc::sync_channel(1);
    assert!(
        command_tx
            .send(ProtocolCommand::Logout { response_tx })
            .is_ok()
    );
    let logout_result = ok(
        ok(
            tokio::task::spawn_blocking(move || response_rx.recv_timeout(Duration::from_secs(2)))
                .await,
            "logout recv task should not panic",
        ),
        "logout response should arrive",
    );
    let Err(message) = logout_result else {
        unreachable!("logout must be rejected without the capability");
    };
    assert!(
        message.contains("auth.logout"),
        "unexpected rejection message: {message}"
    );
    assert!(cancel_tx.send(()).is_ok());
    let protocol_result = ok(
        ok(
            tokio::time::timeout(Duration::from_secs(2), protocol_task).await,
            "protocol should stop after cancel",
        ),
        "protocol task should not panic",
    );
    ok(protocol_result, "protocol should complete cleanly");
    assert!(
        !operations
            .lock()
            .expect("recorded operations")
            .iter()
            .any(|operation| operation == "logout"),
        "agent must not receive a logout request without the capability"
    );

    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}

#[test]
fn auth_required_error_maps_to_auth_required_disconnect() {
    let error = AcpError::auth_required();
    assert_eq!(
        runtime_helpers::disconnect_reason_from_error(&error),
        DisconnectReason::AuthRequired
    );
}

#[tokio::test]
#[cfg(unix)]
async fn run_connection_applies_boolean_config_option() {
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
    let operations = Arc::new(Mutex::new(Vec::<String>::new()));
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(run_agent_recording_boolean_config(
        agent_transport,
        Arc::clone(&operations),
    ));
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let (_command_tx, command_rx) = mpsc::unbounded_channel();
    let project_dir = project.path().to_path_buf();
    let protocol_supervisor = Arc::clone(&supervisor);
    let manager = protocol_manager(
        "fake",
        "agent-acp-1",
        "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e",
    );
    let descriptor = descriptor_with_session_configuration(AcpSessionConfiguration {
        model: AcpSessionModelTransport::Disabled,
        effort: AcpSessionEffortTransport::ConfigOption {
            selector: AcpSessionConfigOptionBinding {
                option_id: Some("web_search".to_string()),
                category: None,
            },
        },
    });
    let request = AcpAgentStartRequest {
        effort: Some("true".to_string()),
        ..AcpAgentStartRequest::default()
    };
    let session_guard = Arc::new(SessionRouteGuard::default());
    let notification_guard = Arc::clone(&session_guard);
    let notification_supervisor = Arc::clone(&supervisor);
    let notification_manager = protocol_manager(
        "fake",
        "agent-acp-1",
        "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e",
    );
    let (routed_tx, _routed_rx) = mpsc::channel(8);

    let protocol_task = tokio::spawn(async move {
        Client
            .builder()
            .name("harness-test")
            .on_receive_notification(
                async move |notification: SessionNotification, _connection| {
                    route_session_notification(
                        &notification_guard,
                        &notification_supervisor,
                        &notification_manager,
                        &routed_tx,
                        notification,
                    )
                    .await
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .connect_with(client_transport, async move |connection| {
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: None,
                    session_config: AcpSessionRequestConfig::from_request(&request, &descriptor),
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                    runtime_name: "fake".to_string(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard,
                    manager,
                    credential: None,
                })
                .await
            })
            .await
    });

    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(cancel_tx.send(()).is_ok());
    let protocol_result = ok(
        ok(
            tokio::time::timeout(Duration::from_secs(2), protocol_task).await,
            "protocol should stop after cancel",
        ),
        "protocol task should not panic",
    );
    ok(protocol_result, "protocol should complete cleanly");
    assert_eq!(
        operations.lock().expect("recorded operations").clone(),
        vec!["set_config:web_search:bool:true".to_string()]
    );
    let state = some(
        supervisor.session_state(),
        "session state should be recorded on the supervisor",
    );
    let options: Vec<(String, String)> = state
        .config_options
        .iter()
        .map(|option| (option.id.clone(), option.current_value.clone()))
        .collect();
    assert_eq!(
        options,
        vec![("web_search".to_string(), "true".to_string())]
    );
    assert_eq!(state.current_mode_id.as_deref(), Some("focus"));
    assert_eq!(state.available_commands, vec!["review".to_string()]);
    assert_eq!(state.title.as_deref(), Some("Renamed"));
    assert_eq!(state.updated_at.as_deref(), Some("2026-07-20T00:00:00Z"));

    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}
