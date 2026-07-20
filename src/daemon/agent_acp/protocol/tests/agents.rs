use std::sync::{Arc, Mutex};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, AvailableCommand, AvailableCommandsUpdate, CancelNotification, ContentBlock,
    ContentChunk, CurrentModeUpdate, Implementation, InitializeRequest, InitializeResponse,
    NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse, SessionConfigBoolean,
    SessionConfigKind, SessionConfigOption, SessionConfigOptionCategory, SessionConfigOptionValue,
    SessionConfigSelect, SessionConfigSelectOption, SessionId, SessionInfoUpdate, SessionMode,
    SessionModeState, SessionNotification, SessionUpdate, SetSessionConfigOptionRequest,
    SetSessionConfigOptionResponse, StopReason, TextContent,
};
use agent_client_protocol::util::internal_error;
use agent_client_protocol::{Agent, Channel, UntypedMessage};

pub(super) const LEGACY_SET_MODEL_METHOD: &str = "session/set_model";

pub(super) async fn run_cookbook_style_agent(
    transport: Channel,
) -> agent_client_protocol::Result<()> {
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

pub(super) async fn run_agent_with_stale_notification(
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

pub(super) async fn run_agent_recording_initialize_contract(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    Agent
        .builder()
        .name("initialize-contract-agent")
        .on_receive_request(
            async move |initialize: InitializeRequest, responder, _connection| {
                let capabilities = &initialize.client_capabilities;
                let boolean = capabilities
                    .session
                    .as_ref()
                    .and_then(|session| session.config_options.as_ref())
                    .is_some_and(|options| options.boolean.is_some());
                let client = initialize.client_info.as_ref().map_or_else(
                    || "none".to_owned(),
                    |info| format!("{}@{}", info.name, info.version),
                );
                operations.lock().expect("record initialize").push(format!(
                    "initialize:read={},write={},terminal={},boolean={boolean},client={client}",
                    capabilities.fs.read_text_file,
                    capabilities.fs.write_text_file,
                    capabilities.terminal,
                ));
                responder.respond(
                    InitializeResponse::new(initialize.protocol_version)
                        .agent_info(Some(Implementation::new(
                            "initialize-contract-agent",
                            "1.2.3",
                        )))
                        .agent_capabilities(AgentCapabilities::new().load_session(true)),
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
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_to(transport)
        .await
}

fn boolean_config_option(current_value: bool) -> SessionConfigOption {
    SessionConfigOption::new(
        "web_search",
        "Web search",
        SessionConfigKind::Boolean(SessionConfigBoolean::new(current_value)),
    )
}

pub(super) async fn run_agent_recording_boolean_config(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    Agent
        .builder()
        .name("boolean-config-agent")
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
                        .modes(SessionModeState::new(
                            "plan",
                            vec![
                                SessionMode::new("plan", "Plan"),
                                SessionMode::new("focus", "Focus"),
                            ],
                        ))
                        .config_options(vec![boolean_config_option(false)]),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: SetSessionConfigOptionRequest, responder, connection| {
                let value = match request.value {
                    SessionConfigOptionValue::Boolean { value } => format!("bool:{value}"),
                    _ => "non-boolean".to_owned(),
                };
                operations
                    .lock()
                    .expect("record boolean set_config")
                    .push(format!("set_config:{}:{value}", request.config_id.0));
                let session_id = SessionId::new("acp-session-1");
                connection.send_notification(SessionNotification::new(
                    session_id.clone(),
                    SessionUpdate::CurrentModeUpdate(CurrentModeUpdate::new("focus")),
                ))?;
                connection.send_notification(SessionNotification::new(
                    session_id.clone(),
                    SessionUpdate::AvailableCommandsUpdate(AvailableCommandsUpdate::new(vec![
                        AvailableCommand::new("review", "Review the diff"),
                    ])),
                ))?;
                connection.send_notification(SessionNotification::new(
                    session_id,
                    SessionUpdate::SessionInfoUpdate(
                        SessionInfoUpdate::new()
                            .title("Renamed".to_owned())
                            .updated_at("2026-07-20T00:00:00Z".to_owned()),
                    ),
                ))?;
                responder.respond(SetSessionConfigOptionResponse::new(vec![
                    boolean_config_option(true),
                ]))
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

pub(super) async fn run_agent_recording_startup_config_order(
    transport: Channel,
    operations: Arc<Mutex<Vec<String>>>,
) -> agent_client_protocol::Result<()> {
    Agent
        .builder()
        .name("startup-config-agent")
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
                    NewSessionResponse::new("acp-session-1").config_options(vec![
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
                    ]),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let operations = Arc::clone(&operations);
                async move |request: SetSessionConfigOptionRequest, responder, _connection| {
                    let value = request
                        .value
                        .as_value_id()
                        .map_or_else(|| "non-select".to_owned(), |id| id.0.to_string());
                    operations
                        .lock()
                        .expect("record startup operation")
                        .push(format!("set_config:{}:{value}", request.config_id.0));
                    responder.respond(SetSessionConfigOptionResponse::new(vec![
                        SessionConfigOption::new(
                            "effort",
                            "Effort",
                            SessionConfigKind::Select(SessionConfigSelect::new(
                                value.clone(),
                                vec![
                                    SessionConfigSelectOption::new("low", "Low"),
                                    SessionConfigSelectOption::new("high", "High"),
                                ],
                            )),
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
                    let recorded = operations.lock().expect("read startup operations").clone();
                    assert_eq!(
                        recorded,
                        vec![
                            "set_model:model-a".to_string(),
                            "set_config:effort:high".to_string(),
                        ]
                    );
                    operations
                        .lock()
                        .expect("record prompt operation")
                        .push("prompt".to_string());
                    responder.respond(PromptResponse::new(StopReason::EndTurn))
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let operations = Arc::clone(&operations);
                async move |request: UntypedMessage, responder, _connection| {
                    if request.method() == LEGACY_SET_MODEL_METHOD {
                        let model = request.params()["modelId"].as_str().unwrap_or_default();
                        operations
                            .lock()
                            .expect("record startup operation")
                            .push(format!("set_model:{model}"));
                        responder.respond(serde_json::json!({}))
                    } else {
                        responder.respond_with_error(internal_error(format!(
                            "startup-config-agent: method '{}' not handled",
                            request.method()
                        )))
                    }
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
