use std::sync::{Arc, Mutex};

use agent_client_protocol::schema::{
    AgentCapabilities, CancelNotification, ContentBlock, ContentChunk, InitializeRequest,
    InitializeResponse, ModelInfo, NewSessionRequest, NewSessionResponse, PromptRequest,
    PromptResponse, SessionConfigKind, SessionConfigOption, SessionConfigOptionCategory,
    SessionConfigSelect, SessionConfigSelectOption, SessionId, SessionModelState,
    SessionNotification, SessionUpdate, SetSessionConfigOptionRequest,
    SetSessionConfigOptionResponse, SetSessionModelRequest, SetSessionModelResponse, StopReason,
    TextContent,
};
use agent_client_protocol::{Agent, Channel};

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
                    NewSessionResponse::new("acp-session-1")
                        .models(SessionModelState::new(
                            "baseline",
                            vec![
                                ModelInfo::new("baseline", "Baseline"),
                                ModelInfo::new("model-a", "Model A"),
                            ],
                        ))
                        .config_options(vec![
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
                async move |request: SetSessionModelRequest, responder, _connection| {
                    operations
                        .lock()
                        .expect("record startup operation")
                        .push(format!("set_model:{}", request.model_id.0));
                    responder.respond(SetSessionModelResponse::new())
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let operations = Arc::clone(&operations);
                async move |request: SetSessionConfigOptionRequest, responder, _connection| {
                    operations
                        .lock()
                        .expect("record startup operation")
                        .push(format!(
                            "set_config:{}:{}",
                            request.config_id.0, request.value.0
                        ));
                    responder.respond(SetSessionConfigOptionResponse::new(vec![
                        SessionConfigOption::new(
                            "effort",
                            "Effort",
                            SessionConfigKind::Select(SessionConfigSelect::new(
                                request.value.clone(),
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
        .on_receive_notification(
            async move |_cancel: CancelNotification, _connection| Ok(()),
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_to(transport)
        .await
}
