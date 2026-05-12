use super::*;
use std::process::Command;
use std::sync::{Arc, Mutex};

use agent_client_protocol::schema::{
    AgentCapabilities, InitializeRequest, InitializeResponse, NewSessionRequest,
    NewSessionResponse, PromptResponse, SessionConfigOption, SessionConfigOptionCategory,
    SessionConfigSelectOption, SetSessionConfigOptionRequest, SetSessionConfigOptionResponse,
    StopReason,
};
use agent_client_protocol::{Channel, Client};

use crate::agents::acp::catalog::{
    AcpAgentDescriptor, AcpSessionConfigOptionBinding, AcpSessionConfiguration,
    AcpSessionEffortTransport, DoctorProbe,
};
use crate::agents::acp::supervision::SupervisionConfig;
use crate::daemon::agent_acp::prompt_gate::{PromptGate, PromptOwner};

fn descriptor_with_session_configuration(
    session_configuration: AcpSessionConfiguration,
) -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: "test-acp".to_string(),
        display_name: "Test ACP".to_string(),
        capabilities: Vec::new(),
        launch_command: "test-acp".to_string(),
        launch_args: Vec::new(),
        env_passthrough: Vec::new(),
        spawn_configuration: Default::default(),
        model_catalog: None,
        install_hint: None,
        session_configuration,
        doctor_probe: DoctorProbe {
            command: "test-acp".to_string(),
            args: vec!["--version".to_string()],
        },
        prompt_timeout_seconds: None,
        excluded_from_initial_default: false,
        bundled_with_harness: false,
    }
}

#[tokio::test]
#[cfg(unix)]
async fn attach_prompt_session_reapplies_session_config_before_prompt() {
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
    let operations = Arc::new(Mutex::new(Vec::<String>::new()));
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(run_agent_recording_attach_config_order(
        agent_transport,
        Arc::clone(&operations),
    ));
    let session_guard = SessionRouteGuard::default();
    let descriptor = descriptor_with_session_configuration(AcpSessionConfiguration {
        model: Default::default(),
        effort: AcpSessionEffortTransport::ConfigOption {
            selector: AcpSessionConfigOptionBinding {
                option_id: Some("effort".to_string()),
                category: Some("effort".to_string()),
            },
        },
    });
    let request = crate::daemon::agent_acp::manager::AcpAgentStartRequest {
        effort: Some("high".to_string()),
        ..crate::daemon::agent_acp::manager::AcpAgentStartRequest::default()
    };
    let session_config = AcpSessionRequestConfig::from_request(&request, &descriptor);

    let protocol_task = tokio::spawn(async move {
        Client
            .builder()
            .name("harness-test")
            .connect_with(client_transport, async move |connection| {
                let session_id = attach_prompt_session(
                    Arc::clone(&supervisor),
                    &connection,
                    &session_guard,
                    Duration::from_secs(1),
                    AttachPromptInput {
                        acp_id: "agent-acp-1".to_string(),
                        session_id: "orchestration-1".to_string(),
                        project_dir: PathBuf::from("/tmp/harness"),
                        session_config,
                        prompt: "resume work".to_string(),
                        prompt_lease: PromptGate::default()
                            .acquire(PromptOwner::new("agent-acp-1", "orchestration-1"))
                            .expect("acquire prompt lease"),
                    },
                )
                .await
                .expect("attach prompt session");
                tokio::time::sleep(Duration::from_millis(100)).await;
                send_cancel_notification(&connection, session_id)
            })
            .await
    });

    protocol_task
        .await
        .expect("protocol task should not panic")
        .expect("attach prompt session should complete");
    assert_eq!(
        operations.lock().expect("recorded operations").clone(),
        vec!["set_config:effort:high".to_string(), "prompt".to_string()]
    );

    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}

async fn run_agent_recording_attach_config_order(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    Agent
        .builder()
        .name("attach-config-agent")
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
                responder.respond(NewSessionResponse::new("attached-session").config_options(
                    vec![
                        SessionConfigOption::select(
                            "effort",
                            "Effort",
                            "medium",
                            vec![
                                SessionConfigSelectOption::new("low", "Low"),
                                SessionConfigSelectOption::new("high", "High"),
                            ],
                        )
                        .category(SessionConfigOptionCategory::Other("effort".to_string())),
                    ],
                ))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let operations = Arc::clone(&operations);
                async move |request: SetSessionConfigOptionRequest, responder, _connection| {
                    operations
                        .lock()
                        .expect("record attach config")
                        .push(format!(
                            "set_config:{}:{}",
                            request.config_id.0, request.value.0
                        ));
                    responder.respond(SetSessionConfigOptionResponse::new(vec![
                        SessionConfigOption::select(
                            "effort",
                            "Effort",
                            request.value.clone(),
                            vec![
                                SessionConfigSelectOption::new("low", "Low"),
                                SessionConfigSelectOption::new("high", "High"),
                            ],
                        )
                        .category(SessionConfigOptionCategory::Other("effort".to_string())),
                    ]))
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let operations = Arc::clone(&operations);
                async move |_request: PromptRequest, responder, _connection| {
                    let recorded = operations.lock().expect("read attach config").clone();
                    assert_eq!(recorded, vec!["set_config:effort:high".to_string()]);
                    operations
                        .lock()
                        .expect("record prompt")
                        .push("prompt".to_string());
                    responder.respond(PromptResponse::new(StopReason::EndTurn))
                }
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
