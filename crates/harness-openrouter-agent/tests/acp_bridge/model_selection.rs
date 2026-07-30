use agent_client_protocol::schema::v1::{
    SessionConfigKind, SessionConfigOptionValue, SessionConfigSelectOptions, SessionId,
    SetSessionConfigOptionRequest,
};

use super::*;

const DEEPSEEK_V4_FLASH: &str = "deepseek/deepseek-v4-flash";

async fn configure_report_only(
    connection: &ConnectionTo<Agent>,
    session_id: &SessionId,
) -> agent_client_protocol::Result<()> {
    connection
        .send_request(SetSessionConfigOptionRequest::new(
            session_id.clone(),
            "model",
            SessionConfigOptionValue::ValueId {
                value: DEEPSEEK_V4_FLASH.into(),
            },
        ))
        .block_task()
        .await?;
    connection
        .send_request(SetSessionConfigOptionRequest::new(
            session_id.clone(),
            "harness_capability_profile",
            SessionConfigOptionValue::ValueId {
                value: "report_only".into(),
            },
        ))
        .block_task()
        .await?;
    Ok(())
}

async fn assert_report_only_provider_model(
    provider_model: Option<&str>,
    provider_tool_call: bool,
    expected_error: Option<&str>,
) {
    let server = MockServer::start().await;
    mount_models(&server).await;
    let mut chunk = if provider_tool_call {
        serde_json::json!({
            "id": "model-proof",
            "choices": [{
                "index": 0,
                "delta": {"tool_calls": [{
                    "index": 0,
                    "id": "forbidden",
                    "type": "function",
                    "function": {
                        "name": "write_text_file",
                        "arguments": "{\"path\":\"forbidden\",\"content\":\"mutation\"}"
                    }
                }]},
                "finish_reason": "tool_calls"
            }]
        })
    } else {
        serde_json::json!({
            "id": "model-proof",
            "choices": [{
                "index": 0,
                "delta": {"content": "review"},
                "finish_reason": "stop"
            }]
        })
    };
    if let Some(provider_model) = provider_model {
        chunk["model"] = provider_model.into();
    }
    let chunk = chunk.to_string();
    let body = sse(&[&chunk]);
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(body),
        )
        .expect(1)
        .mount(&server)
        .await;
    let (agent, _key_tmp) = build_agent(&server.uri());
    let log = ChunkLog::default();
    let observed = log.clone();

    client_builder_with_chunks(log)
        .connect_with(agent, |connection: ConnectionTo<Agent>| async move {
            connection
                .send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let session = connection
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            configure_report_only(&connection, &session.session_id).await?;
            let result = connection
                .send_request(PromptRequest::new(
                    session.session_id,
                    vec![ContentBlock::Text(TextContent::new("review"))],
                ))
                .block_task()
                .await;
            if let Some(expected_error) = expected_error {
                let error = result.expect_err("report-only response must fail");
                assert!(
                    error.message.contains(expected_error),
                    "unexpected error: {error:?}"
                );
            } else {
                assert!(matches!(
                    result.expect("matching provider model").stop_reason,
                    StopReason::EndTurn
                ));
            }
            Ok(())
        })
        .await
        .expect("connection drives to completion");
    assert_eq!(
        observed.effective_model_snapshot(),
        provider_model
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<_>>()
    );
    let requests = server
        .received_requests()
        .await
        .expect("recorded OpenRouter requests");
    let request = requests
        .iter()
        .find(|request| request.url.path() == "/chat/completions")
        .expect("chat completion request");
    let body: serde_json::Value = serde_json::from_slice(&request.body).expect("chat request JSON");
    assert_eq!(body["model"], DEEPSEEK_V4_FLASH);
    assert!(
        body.get("tools")
            .is_none_or(|tools| tools.as_array().is_some_and(Vec::is_empty))
    );
    assert!(
        body.get("tool_choice")
            .is_none_or(serde_json::Value::is_null)
    );
}

#[tokio::test]
async fn report_only_accepts_the_matching_provider_model() {
    assert_report_only_provider_model(Some(DEEPSEEK_V4_FLASH), false, None).await;
}

#[tokio::test]
async fn report_only_rejects_a_mismatched_provider_model() {
    assert_report_only_provider_model(Some("openai/gpt-5.4"), false, Some("provider reported"))
        .await;
}

#[tokio::test]
async fn report_only_rejects_a_missing_provider_model() {
    assert_report_only_provider_model(None, false, Some("provider reported")).await;
}

#[tokio::test]
async fn report_only_refuses_an_unsolicited_provider_tool_call() {
    assert_report_only_provider_model(
        Some(DEEPSEEK_V4_FLASH),
        true,
        Some("refused a provider tool call"),
    )
    .await;
}

#[tokio::test]
async fn requested_model_survives_acp_and_reaches_openrouter() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    let body = sse(&[
        r#"{"id":"model-proof","choices":[{"index":0,"delta":{"content":"selected"},"finish_reason":"stop"}]}"#,
    ]);
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(|request: &Request| {
            serde_json::from_slice::<serde_json::Value>(&request.body)
                .is_ok_and(|body| body["model"] == DEEPSEEK_V4_FLASH)
        })
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(body),
        )
        .expect(1)
        .mount(&server)
        .await;
    let (agent, _key_tmp) = build_agent(&server.uri());

    client_builder_with_chunks(ChunkLog::default())
        .connect_with(agent, |connection: ConnectionTo<Agent>| async move {
            connection
                .send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let session = connection
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            let advertised = session.config_options.as_deref().expect("config options");
            let model = advertised
                .iter()
                .find(|option| option.id.0.as_ref() == "model")
                .expect("model option");
            let SessionConfigKind::Select(select) = &model.kind else {
                panic!("model option must be select");
            };
            let SessionConfigSelectOptions::Ungrouped(options) = &select.options else {
                panic!("model choices must be ungrouped");
            };
            assert!(
                options
                    .iter()
                    .any(|option| option.value.0.as_ref() == DEEPSEEK_V4_FLASH)
            );

            let configured = connection
                .send_request(SetSessionConfigOptionRequest::new(
                    session.session_id.clone(),
                    "model",
                    SessionConfigOptionValue::ValueId {
                        value: DEEPSEEK_V4_FLASH.into(),
                    },
                ))
                .block_task()
                .await?;
            let effective = configured
                .config_options
                .iter()
                .find(|option| option.id.0.as_ref() == "model")
                .expect("effective model option");
            let SessionConfigKind::Select(select) = &effective.kind else {
                panic!("effective model option must be select");
            };
            assert_eq!(select.current_value.0.as_ref(), DEEPSEEK_V4_FLASH);

            let response = connection
                .send_request(PromptRequest::new(
                    session.session_id,
                    vec![ContentBlock::Text(TextContent::new("prove selection"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(response.stop_reason, StopReason::EndTurn));
            Ok(())
        })
        .await
        .expect("connection drives to completion");
}
