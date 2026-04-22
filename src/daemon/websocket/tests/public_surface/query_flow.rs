use super::super::*;

#[tokio::test]
async fn websocket_round_trip_smoke_covers_public_surface() {
    let mut replay_buffer = ReplayBuffer::new(4);
    let first_seq = replay_buffer.append("event-1".into());
    let second_seq = replay_buffer.append("event-2".into());
    assert_eq!(replay_buffer.current_seq(), 2);
    assert_eq!(
        replay_buffer.replay_since(first_seq),
        Some(vec![(second_seq, String::from("event-2"))])
    );

    let state = test_http_state_with_db();
    seed_sample_timeline(&state);
    let request = WsRequest {
        id: "req-smoke".into(),
        method: "session.timeline".into(),
        params: serde_json::json!({
            "session_id": "sess-test-1",
            "scope": "summary",
        }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;
    let frames = serialize_response_frames(&response).expect("serialize websocket response");
    assert_eq!(frames.len(), 1);

    let Message::Text(text) = &frames[0] else {
        panic!("expected inline websocket response frame");
    };
    let response: WsResponse = serde_json::from_str(text).expect("deserialize websocket response");
    assert_eq!(response.id, "req-smoke");
    assert!(response.error.is_none());
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["revision"].as_i64()),
        Some(1)
    );
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["entries"].as_array())
            .map(Vec::len),
        Some(1)
    );
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["entries"].as_array())
            .and_then(|entries| entries.first())
            .and_then(|entry| entry["kind"].as_str()),
        Some("tool_result")
    );
}

#[tokio::test]
async fn websocket_async_detail_query_succeeds_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let request = WsRequest {
        id: "req-detail-async".into(),
        method: "session.detail".into(),
        params: serde_json::json!({ "session_id": "sess-test-1" }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["session"]["session_id"].as_str()),
        Some("sess-test-1")
    );
}

#[tokio::test]
async fn websocket_async_diagnostics_query_succeeds_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let request = WsRequest {
        id: "req-diagnostics-async".into(),
        method: "diagnostics".into(),
        params: serde_json::json!({}),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    assert!(
        response
            .result
            .as_ref()
            .is_some_and(|result| result["recent_events"].is_array())
    );
}

#[tokio::test]
async fn session_subscribe_broadcasts_async_snapshot_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let mut receiver = state.sender.subscribe();
    let request = WsRequest {
        id: "req-session-subscribe".into(),
        method: "session.subscribe".into(),
        params: serde_json::json!({ "session_id": "sess-test-1" }),
        trace_context: None,
    };

    let response = handle_session_subscribe(&request, &state, &connection).await;

    assert!(response.error.is_none());
    assert_eq!(
        receiver.recv().await.expect("sessions_updated").event,
        "sessions_updated"
    );
    assert_eq!(
        receiver.recv().await.expect("session_updated").event,
        "session_updated"
    );
    assert_eq!(
        receiver.recv().await.expect("session_extensions").event,
        "session_extensions"
    );
}

#[tokio::test]
async fn stream_subscribe_broadcasts_async_index_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let mut receiver = state.sender.subscribe();
    let request = WsRequest {
        id: "req-stream-subscribe".into(),
        method: "stream.subscribe".into(),
        params: serde_json::json!({}),
        trace_context: None,
    };

    let response = handle_stream_subscribe(&request, &state, &connection).await;

    assert!(response.error.is_none());
    assert_eq!(
        receiver.recv().await.expect("sessions_updated").event,
        "sessions_updated"
    );
}

#[tokio::test]
async fn websocket_contract_mapped_methods_are_dispatchable() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));

    for method in mapped_ws_methods() {
        let request = WsRequest {
            id: format!("req-{method}"),
            method: method.into(),
            params: serde_json::json!({}),
            trace_context: None,
        };

        let response = dispatch(&request, &state, &connection).await;
        assert_ne!(
            response.error.as_ref().map(|error| error.code.as_str()),
            Some("UNKNOWN_METHOD"),
            "{method} is present in the parity contract but not dispatchable"
        );
    }
}

#[tokio::test]
async fn websocket_top_level_dispatch_reaches_runtime_session_resolve() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let request = WsRequest {
        id: "req-runtime-session-resolve".into(),
        method: ws_methods::RUNTIME_SESSION_RESOLVE.into(),
        params: serde_json::json!({}),
        trace_context: None,
    };

    let response = dispatch(&request, &state, &connection).await;

    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("MISSING_PARAM")
    );
    assert_eq!(
        response.error.as_ref().map(|error| error.message.as_str()),
        Some("missing runtime_name")
    );
}
