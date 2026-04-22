use super::super::*;

#[tokio::test]
async fn websocket_async_task_create_mutation_succeeds_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let request = WsRequest {
        id: "req-task-create-async".into(),
        method: "task.create".into(),
        params: serde_json::json!({
            "session_id": "sess-test-1",
            "actor": "spoofed-client",
            "title": "async websocket task",
            "context": "prefer sqlx websocket path",
            "severity": "high",
            "suggested_fix": "use async mutation dispatcher"
        }),
        trace_context: None,
    };

    let response = dispatch(&request, &state, &connection).await;

    assert!(response.error.is_none());
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["tasks"].as_array())
            .map(Vec::len),
        Some(1)
    );
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["tasks"].as_array())
            .and_then(|tasks| tasks.first())
            .and_then(|task| task["title"].as_str()),
        Some("async websocket task")
    );
}

#[test]
fn websocket_async_signal_cancel_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("ws-async-signal-cancel-leader")),
                ("CODEX_SESSION_ID", Some("ws-async-signal-cancel-worker")),
            ],
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    start_async_session(&state, &project_dir, "ws-async-signal-cancel").await;
                    let worker_id = join_async_worker(
                        &state,
                        "ws-async-signal-cancel",
                        &project_dir,
                        "Async WS Signal Worker",
                    )
                    .await;
                    let leader_id = leader_id_for_session(&state, "ws-async-signal-cancel").await;
                    let signal_id = seed_pending_signal(
                        &state,
                        "ws-async-signal-cancel",
                        &leader_id,
                        &worker_id,
                        &project_dir,
                        "cancel from websocket",
                    )
                    .await;
                    let connection = Arc::new(Mutex::new(ConnectionState::new()));
                    let request = WsRequest {
                        id: "req-signal-cancel-async".into(),
                        method: "signal.cancel".into(),
                        params: serde_json::json!({
                            "session_id": "ws-async-signal-cancel",
                            "actor": "spoofed-client",
                            "agent_id": worker_id,
                            "signal_id": signal_id.clone()
                        }),
                        trace_context: None,
                    };

                    let response = dispatch(&request, &state, &connection).await;

                    assert!(response.error.is_none());
                    let async_db = state.async_db.get().expect("async db");
                    assert_eq!(
                        async_db
                            .load_signals("ws-async-signal-cancel")
                            .await
                            .expect("load signals")
                            .into_iter()
                            .find(|signal| signal.signal.signal_id == signal_id)
                            .map(|signal| signal.status),
                        Some(SessionSignalStatus::Rejected)
                    );
                });
            },
        );
    });
}

#[test]
fn websocket_session_delete_returns_deleted_flag() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let project_dir = sandbox.path().join("project");
            init_git_project(&project_dir);

            let db_path = sandbox.path().join("daemon.sqlite");
            let state = test_websocket_state_with_empty_async_db(&db_path).await;
            start_async_session(&state, &project_dir, "ws-delete-session").await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));
            let request = WsRequest {
                id: "req-session-delete".into(),
                method: ws_methods::SESSION_DELETE.into(),
                params: serde_json::json!({
                    "session_id": "ws-delete-session",
                }),
                trace_context: None,
            };

            let response = dispatch(&request, &state, &connection).await;

            assert!(response.error.is_none());
            assert_eq!(
                response
                    .result
                    .as_ref()
                    .and_then(|result| result["deleted"].as_bool()),
                Some(true)
            );
            let async_db = state.async_db.get().expect("async db");
            assert!(
                async_db
                    .resolve_session("ws-delete-session")
                    .await
                    .expect("resolve deleted session")
                    .is_none()
            );
        });
    });
}

#[test]
fn websocket_async_signal_ack_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("ws-async-signal-ack-leader")),
                ("CODEX_SESSION_ID", Some("ws-async-signal-ack-worker")),
            ],
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    start_async_session(&state, &project_dir, "ws-async-signal-ack").await;
                    let worker_id = join_async_worker(
                        &state,
                        "ws-async-signal-ack",
                        &project_dir,
                        "Async WS Signal Ack Worker",
                    )
                    .await;
                    let leader_id = leader_id_for_session(&state, "ws-async-signal-ack").await;
                    let signal_id = seed_pending_signal(
                        &state,
                        "ws-async-signal-ack",
                        &leader_id,
                        &worker_id,
                        &project_dir,
                        "ack from websocket",
                    )
                    .await;
                    let connection = Arc::new(Mutex::new(ConnectionState::new()));
                    let request = WsRequest {
                        id: "req-signal-ack-async".into(),
                        method: ws_methods::SIGNAL_ACK.into(),
                        params: serde_json::json!({
                            "session_id": "ws-async-signal-ack",
                            "agent_id": worker_id,
                            "signal_id": signal_id.clone(),
                            "result": "accepted",
                            "project_dir": project_dir,
                        }),
                        trace_context: None,
                    };

                    let response = dispatch(&request, &state, &connection).await;

                    assert!(response.error.is_none());
                    assert_eq!(
                        response
                            .result
                            .as_ref()
                            .and_then(|result| result["ok"].as_bool()),
                        Some(true)
                    );
                    let async_db = state.async_db.get().expect("async db");
                    assert_eq!(
                        async_db
                            .load_signals("ws-async-signal-ack")
                            .await
                            .expect("load signals")
                            .into_iter()
                            .find(|signal| signal.signal.signal_id == signal_id)
                            .map(|signal| signal.status),
                        Some(SessionSignalStatus::Delivered)
                    );
                });
            },
        );
    });
}

#[test]
fn websocket_managed_agent_input_errors_include_http_status_metadata() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let request = WsRequest {
            id: "req-managed-agent-input-missing".into(),
            method: ws_methods::MANAGED_AGENT_INPUT.into(),
            params: serde_json::json!({
                "agent_id": "missing-agent",
                "input": {
                    "type": "text",
                    "text": "hello"
                }
            }),
            trace_context: None,
        };

        let response = dispatch(&request, &state, &connection).await;
        let error = response.error.expect("error response");
        assert_eq!(error.code, "KSRCLI090");
        assert_eq!(error.status_code, Some(400));
        assert!(
            error
                .data
                .as_ref()
                .and_then(|data| data["error"]["message"].as_str())
                .is_some_and(|message| message.contains("managed agent 'missing-agent' not found"))
        );
    });
}

#[test]
fn websocket_voice_mutations_round_trip() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "HARNESS_DAEMON_DATA_HOME",
            Some(sandbox.path().to_string_lossy().as_ref()),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let state = test_http_state_with_db();
                    let connection = Arc::new(Mutex::new(ConnectionState::new()));

                    let start_request = WsRequest {
                        id: "req-voice-start".into(),
                        method: ws_methods::VOICE_START_SESSION.into(),
                        params: serde_json::json!({
                            "session_id": "voice-session-parent",
                            "actor": "harness-app",
                            "locale_identifier": "en_US",
                            "requested_sinks": ["localDaemon"],
                            "route_target": {
                                "kind": "codexPrompt",
                                "run_id": null,
                                "agent_id": null,
                                "command": null,
                                "action_hint": null
                            },
                            "requires_confirmation": true,
                            "remote_processor_url": null
                        }),
                        trace_context: None,
                    };

                    let started = dispatch(&start_request, &state, &connection).await;
                    assert!(started.error.is_none());
                    let voice_session_id = started
                        .result
                        .as_ref()
                        .and_then(|result| result["voice_session_id"].as_str())
                        .expect("voice session id")
                        .to_string();

                    let append_audio = WsRequest {
                        id: "req-voice-audio".into(),
                        method: ws_methods::VOICE_APPEND_AUDIO.into(),
                        params: serde_json::json!({
                            "voice_session_id": voice_session_id,
                            "actor": "harness-app",
                            "sequence": 1,
                            "format": {
                                "sample_rate": 48_000.0,
                                "channel_count": 1,
                                "common_format": "pcm_f32",
                                "interleaved": false
                            },
                            "frame_count": 4,
                            "started_at_seconds": 0.0,
                            "duration_seconds": 0.01,
                            "audio_base64": "AQIDBA=="
                        }),
                        trace_context: None,
                    };
                    let audio_response = dispatch(&append_audio, &state, &connection).await;
                    assert!(audio_response.error.is_none());

                    let append_transcript = WsRequest {
                        id: "req-voice-transcript".into(),
                        method: ws_methods::VOICE_APPEND_TRANSCRIPT.into(),
                        params: serde_json::json!({
                            "voice_session_id": append_audio
                                .params["voice_session_id"]
                                .as_str()
                                .expect("voice session id"),
                            "actor": "harness-app",
                            "segment": {
                                "sequence": 1,
                                "text": "patch the failing test",
                                "is_final": true,
                                "started_at_seconds": 0.0,
                                "duration_seconds": 0.5,
                                "confidence": null
                            }
                        }),
                        trace_context: None,
                    };
                    let transcript_response =
                        dispatch(&append_transcript, &state, &connection).await;
                    assert!(transcript_response.error.is_none());

                    let finish_request = WsRequest {
                        id: "req-voice-finish".into(),
                        method: ws_methods::VOICE_FINISH_SESSION.into(),
                        params: serde_json::json!({
                            "voice_session_id": append_transcript
                                .params["voice_session_id"]
                                .as_str()
                                .expect("voice session id"),
                            "actor": "harness-app",
                            "reason": "completed",
                            "confirmed_text": "patch the failing test"
                        }),
                        trace_context: None,
                    };
                    let finished = dispatch(&finish_request, &state, &connection).await;
                    assert!(finished.error.is_none());
                    assert_eq!(
                        finished
                            .result
                            .as_ref()
                            .and_then(|result| result["status"].as_str()),
                        Some("completed")
                    );
                });
            },
        );
    });
}
