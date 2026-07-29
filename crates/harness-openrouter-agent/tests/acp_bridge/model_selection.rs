use agent_client_protocol::schema::v1::{
    SessionConfigKind, SessionConfigOptionValue, SessionConfigSelectOptions,
    SetSessionConfigOptionRequest,
};

use super::*;

const DEEPSEEK_V4_FLASH: &str = "deepseek/deepseek-v4-flash";

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
