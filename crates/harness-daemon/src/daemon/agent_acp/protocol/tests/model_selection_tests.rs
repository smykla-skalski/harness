use crate::daemon::agent_acp::{AgentTurnFailure, AgentTurnFailureCategory, AgentTurnFailureStage};
use agent_client_protocol::schema::v1::{
    AgentCapabilities, InitializeRequest, InitializeResponse, NewSessionRequest,
    NewSessionResponse, PromptRequest, PromptResponse, SessionConfigKind, SessionConfigOption,
    SessionConfigOptionCategory, SessionConfigSelect, SessionConfigSelectOption,
    SetSessionConfigOptionRequest, SetSessionConfigOptionResponse, StopReason,
};
use agent_client_protocol::{Agent, Channel, Client};

use super::*;

const DEEPSEEK_V4_FLASH: &str = "deepseek/deepseek-v4-flash";

async fn run_model_agent(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
    prompt_tx: mpsc::UnboundedSender<()>,
) -> agent_client_protocol::Result<()> {
    let set_operations = Arc::clone(&operations);
    Agent
        .builder()
        .name("model-selection-agent")
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
                responder.respond(
                    NewSessionResponse::new("acp-session-1")
                        .config_options(vec![model_option("default/model")]),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: SetSessionConfigOptionRequest, responder, _connection| {
                let value = request
                    .value
                    .as_value_id()
                    .map_or_else(|| "non-select".to_owned(), |value| value.0.to_string());
                set_operations
                    .lock()
                    .expect("record model configuration")
                    .push(format!("set_model:{value}"));
                responder.respond(SetSessionConfigOptionResponse::new(vec![model_option(
                    &value,
                )]))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: PromptRequest, responder, _connection| {
                operations
                    .lock()
                    .expect("record prompt")
                    .push("prompt".to_owned());
                let _ = prompt_tx.send(());
                responder.respond(PromptResponse::new(StopReason::EndTurn))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_to(transport)
        .await
}

fn model_option(current: &str) -> SessionConfigOption {
    SessionConfigOption::new(
        "model",
        "Model",
        SessionConfigKind::Select(SessionConfigSelect::new(
            current.to_owned(),
            vec![
                SessionConfigSelectOption::new("default/model", "Default"),
                SessionConfigSelectOption::new(DEEPSEEK_V4_FLASH, "DeepSeek V4 Flash"),
            ],
        )),
    )
    .category(SessionConfigOptionCategory::Model)
}

fn model_session_config(model: &str) -> AcpSessionRequestConfig {
    let descriptor = descriptor_with_session_configuration(AcpSessionConfiguration {
        model: AcpSessionModelTransport::ConfigOption {
            selector: AcpSessionConfigOptionBinding {
                option_id: Some("model".to_owned()),
                category: Some("model".to_owned()),
            },
        },
        ..Default::default()
    });
    AcpSessionRequestConfig::from_request(
        &AcpAgentStartRequest {
            prompt: Some("prove model".to_owned()),
            model: Some(model.to_owned()),
            ..AcpAgentStartRequest::default()
        },
        &descriptor,
    )
}

async fn run_model_connection(
    model: &str,
) -> (
    agent_client_protocol::Result<()>,
    Vec<String>,
    Option<crate::daemon::agent_acp::AcpAgentSessionState>,
) {
    let project = tempfile::tempdir().expect("project tempdir");
    let supervisor_child = ChildGuard(
        Command::new("sleep")
            .arg("60")
            .spawn()
            .expect("spawn supervisor child"),
    );
    let supervisor = Arc::new(AcpSessionSupervisor::new(
        &supervisor_child.0,
        SupervisionConfig {
            initialize_timeout: Duration::from_secs(1),
            prompt_timeout: Duration::from_secs(1),
            ..SupervisionConfig::default()
        },
    ));
    let operations = Arc::new(Mutex::new(Vec::new()));
    let (client_transport, agent_transport) = Channel::duplex();
    let (prompt_tx, mut prompt_rx) = mpsc::unbounded_channel();
    let agent_task = tokio::spawn(run_model_agent(
        agent_transport,
        Arc::clone(&operations),
        prompt_tx,
    ));
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let (_command_tx, command_rx) = mpsc::unbounded_channel();
    let project_dir = project.path().to_path_buf();
    let session_config = model_session_config(model);
    let protocol_supervisor = Arc::clone(&supervisor);
    let mut protocol_task = tokio::spawn(async move {
        Client
            .builder()
            .name("harness-test")
            .connect_with(client_transport, async move |connection| {
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: Some("prove model".to_owned()),
                    session_config,
                    resume_session_id: None,
                    acp_id: "agent-acp-1".to_owned(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_owned(),
                    runtime_name: "fake".to_owned(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard: Arc::new(SessionRouteGuard::default()),
                    manager: protocol_manager(
                        "fake",
                        "agent-acp-1",
                        "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e",
                    ),
                    credential: None,
                })
                .await
            })
            .await
    });
    let result = tokio::time::timeout(Duration::from_secs(2), async {
        tokio::select! {
            result = &mut protocol_task => result.expect("model protocol task must not panic"),
            prompt = prompt_rx.recv() => {
                if prompt.is_some() {
                    let _ = cancel_tx.send(());
                }
                protocol_task.await.expect("model protocol task must not panic")
            }
        }
    })
    .await
    .expect("model protocol must complete");
    agent_task.abort();
    let _ = agent_task.await;
    let recorded = operations.lock().expect("recorded operations").clone();
    (result, recorded, supervisor.session_state())
}

#[tokio::test]
#[cfg(unix)]
async fn supported_model_is_configured_before_prompt() {
    let (result, operations, state) = run_model_connection(DEEPSEEK_V4_FLASH).await;

    assert!(result.is_ok(), "supported model failed: {result:?}");
    assert_eq!(
        operations,
        vec![
            format!("set_model:{DEEPSEEK_V4_FLASH}"),
            "prompt".to_owned(),
        ]
    );
    let state = state.expect("session state");
    assert_eq!(
        state
            .config_options
            .iter()
            .find(|option| option.id == "model")
            .map(|option| option.current_value.as_str()),
        Some(DEEPSEEK_V4_FLASH)
    );
}

#[tokio::test]
#[cfg(unix)]
async fn unsupported_model_fails_before_prompt() {
    let (result, operations, _state) = run_model_connection("unsupported/model").await;

    let error = result.expect_err("unsupported model must fail");
    assert!(
        error
            .to_string()
            .contains("does not accept 'unsupported/model'")
    );
    let failure: AgentTurnFailure =
        serde_json::from_value(error.data.expect("unsupported model failure data"))
            .expect("decode unsupported model failure");
    assert_eq!(failure.category, AgentTurnFailureCategory::UnsupportedModel);
    assert_eq!(failure.stage, AgentTurnFailureStage::Start);
    assert!(!failure.automatic_retry_safe);
    assert!(operations.is_empty(), "agent work began: {operations:?}");
}
