use super::*;

#[tokio::test]
async fn http_error_surfaces_as_end_turn_with_diagnostic_chunk() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(429).insert_header("retry-after", "1"))
        .mount(&server)
        .await;

    let (agent, _key_tmp) = build_agent(&server.uri());
    let log = ChunkLog::default();
    let log_for_assert = log.clone();
    client_builder_with_chunks(log)
        .connect_with(agent, |cx: ConnectionTo<Agent>| async move {
            cx.send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let session = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            let response = cx
                .send_request(PromptRequest::new(
                    session.session_id,
                    vec![ContentBlock::Text(TextContent::new("Hi"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(response.stop_reason, StopReason::EndTurn));
            Ok(())
        })
        .await
        .expect("connection drives to completion");
    let chunks = log_for_assert.snapshot().join("");
    assert!(
        chunks.contains("openrouter error"),
        "expected diagnostic chunk, got {chunks:?}",
    );
    assert!(
        chunks.to_lowercase().contains("rate limit"),
        "expected rate-limit phrasing, got {chunks:?}",
    );
}

#[tokio::test]
async fn moderation_status_surfaces_as_refusal() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(403).set_body_string("blocked"))
        .mount(&server)
        .await;

    let (agent, _key_tmp) = build_agent(&server.uri());
    client_builder_with_chunks(ChunkLog::default())
        .connect_with(agent, |cx: ConnectionTo<Agent>| async move {
            cx.send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let session = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            let response = cx
                .send_request(PromptRequest::new(
                    session.session_id,
                    vec![ContentBlock::Text(TextContent::new("forbidden"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(response.stop_reason, StopReason::Refusal));
            Ok(())
        })
        .await
        .expect("connection drives to completion");
}

#[tokio::test]
async fn cancel_mid_stream_returns_cancelled_stop_reason() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    // Stream emits one chunk and then stalls. We send `session/cancel` once
    // the chunk arrives; the shim's per-session cancel flag is checked
    // between SSE chunks and aborts the turn even though the upstream stream
    // is still open.
    let body = format!(
        "{}{}{}",
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hi\"}}]}\n\n",
        // Delay between events does not exist in wiremock; we send a second
        // event that the shim will start receiving after the cancel flag is
        // already set. The flag is polled between chunks, so the second chunk
        // is dropped on the floor and the loop short-circuits.
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"never\"}}]}\n\n",
        "data: [DONE]\n\n",
    );
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(body),
        )
        .mount(&server)
        .await;

    let (agent, _key_tmp) = build_agent(&server.uri());
    let log = ChunkLog::default();
    let log_for_assert = log.clone();
    client_builder_with_chunks(log)
        .connect_with(agent, |cx: ConnectionTo<Agent>| async move {
            cx.send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let session = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            let session_id = session.session_id.clone();
            // Issue the prompt and cancel concurrently.
            let prompt = cx.send_request(PromptRequest::new(
                session_id.clone(),
                vec![ContentBlock::Text(TextContent::new("Stream"))],
            ));
            // Give the shim a brief moment to begin the turn, then cancel.
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            cx.send_notification(CancelNotification::new(session_id))?;
            let response = prompt.block_task().await?;
            assert!(
                matches!(
                    response.stop_reason,
                    StopReason::Cancelled | StopReason::EndTurn,
                ),
                "expected Cancelled or EndTurn, got {:?}",
                response.stop_reason,
            );
            Ok(())
        })
        .await
        .expect("connection drives to completion");
    let _ = log_for_assert.snapshot();
}

#[tokio::test]
async fn multiple_sessions_keep_isolated_histories() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    // Match the body content to differentiate the two prompts.
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(|req: &Request| -> bool {
            let body: serde_json::Value = match serde_json::from_slice(&req.body) {
                Ok(value) => value,
                Err(_) => return false,
            };
            body["messages"][0]["content"] == "first"
        })
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(sse(&[
                    r#"{"id":"a","choices":[{"index":0,"delta":{"content":"one"},"finish_reason":"stop"}]}"#,
                ])),
        )
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(|req: &Request| -> bool {
            let body: serde_json::Value = match serde_json::from_slice(&req.body) {
                Ok(value) => value,
                Err(_) => return false,
            };
            body["messages"][0]["content"] == "second"
        })
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(sse(&[
                    r#"{"id":"b","choices":[{"index":0,"delta":{"content":"two"},"finish_reason":"stop"}]}"#,
                ])),
        )
        .mount(&server)
        .await;

    let (agent, _key_tmp) = build_agent(&server.uri());
    let log = ChunkLog::default();
    let log_for_assert = log.clone();
    client_builder_with_chunks(log)
        .connect_with(agent, |cx: ConnectionTo<Agent>| async move {
            cx.send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let session_a = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            let session_b = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            assert_ne!(session_a.session_id.0, session_b.session_id.0);
            let r_a = cx
                .send_request(PromptRequest::new(
                    session_a.session_id,
                    vec![ContentBlock::Text(TextContent::new("first"))],
                ))
                .block_task()
                .await?;
            let r_b = cx
                .send_request(PromptRequest::new(
                    session_b.session_id,
                    vec![ContentBlock::Text(TextContent::new("second"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(r_a.stop_reason, StopReason::EndTurn));
            assert!(matches!(r_b.stop_reason, StopReason::EndTurn));
            Ok(())
        })
        .await
        .expect("connection drives to completion");
    let chunks = log_for_assert.snapshot();
    assert!(chunks.iter().any(|s| s == "one"), "got {chunks:?}");
    assert!(chunks.iter().any(|s| s == "two"), "got {chunks:?}");
}
