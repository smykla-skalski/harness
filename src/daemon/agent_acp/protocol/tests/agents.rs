use std::sync::{Arc, Mutex};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, ContentBlock, ContentChunk, InitializeRequest,
    InitializeResponse, NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse,
    SessionConfigKind, SessionConfigOption, SessionConfigOptionCategory, SessionConfigSelect,
    SessionConfigSelectOption, SessionId, SessionNotification, SessionUpdate,
    SetSessionConfigOptionRequest, SetSessionConfigOptionResponse, StopReason, TextContent,
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
                responder.respond(NewSessionResponse::new("acp-session-1").config_options(vec![
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
                    ]))
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
