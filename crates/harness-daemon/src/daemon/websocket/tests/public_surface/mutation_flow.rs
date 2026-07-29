use super::super::*;

mod voice;

#[test]
fn websocket_async_task_create_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("b03dd87b-ec33-50dc-8df3-b6671d0e3051-leader"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    start_async_session(
                        &state,
                        &project_dir,
                        "b03dd87b-ec33-50dc-8df3-b6671d0e3051",
                    )
                    .await;
                    let connection = Arc::new(Mutex::new(ConnectionState::new()));
                    let request = WsRequest {
                        id: "req-task-create-async".into(),
                        method: "task.create".into(),
                        params: serde_json::json!({
                            "session_id": "b03dd87b-ec33-50dc-8df3-b6671d0e3051",
                            "actor": "spoofed-client",
                            "title": "async websocket task",
                            "context": "prefer sqlx websocket path",
                            "severity": "high",
                            "suggested_fix": "use async mutation dispatcher"
                        }),
                        trace_context: None,
                    };

                    let response = dispatch(&request, &state, &connection).await;

                    assert!(
                        response.error.is_none(),
                        "unexpected websocket error: {:?}",
                        response.error
                    );
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
                });
            },
        );
    });
}

#[test]
fn websocket_async_signal_cancel_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                (
                    "CLAUDE_SESSION_ID",
                    Some("3c87ca21-37f8-5d6e-8dfd-b7c059d5ec2f-leader"),
                ),
                (
                    "CODEX_SESSION_ID",
                    Some("3c87ca21-37f8-5d6e-8dfd-b7c059d5ec2f-worker"),
                ),
            ],
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    start_async_session(
                        &state,
                        &project_dir,
                        "3c87ca21-37f8-5d6e-8dfd-b7c059d5ec2f",
                    )
                    .await;
                    let worker_id = join_async_worker(
                        &state,
                        "3c87ca21-37f8-5d6e-8dfd-b7c059d5ec2f",
                        &project_dir,
                        "Async WS Signal Worker",
                    )
                    .await;
                    let leader_id =
                        leader_id_for_session(&state, "3c87ca21-37f8-5d6e-8dfd-b7c059d5ec2f").await;
                    let signal_id = seed_pending_signal(
                        &state,
                        "3c87ca21-37f8-5d6e-8dfd-b7c059d5ec2f",
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
                            "session_id": "3c87ca21-37f8-5d6e-8dfd-b7c059d5ec2f",
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
                            .load_signals("3c87ca21-37f8-5d6e-8dfd-b7c059d5ec2f")
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
            start_async_session(&state, &project_dir, "64fc43e3-b329-5b2e-a721-8882f05224ed").await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));
            let request = WsRequest {
                id: "req-session-delete".into(),
                method: ws_methods::SESSION_DELETE.into(),
                params: serde_json::json!({
                    "session_id": "64fc43e3-b329-5b2e-a721-8882f05224ed",
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
                    .resolve_session("64fc43e3-b329-5b2e-a721-8882f05224ed")
                    .await
                    .expect("resolve deleted session")
                    .is_none()
            );
        });
    });
}

#[test]
fn websocket_session_archive_returns_archived_at_and_hides_session() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("3516d468-9b26-5344-accb-fc669db672e5-leader"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    let session_id = "3516d468-9b26-5344-accb-fc669db672e5";
                    start_async_session(&state, &project_dir, session_id).await;
                    let connection = Arc::new(Mutex::new(ConnectionState::new()));
                    let request = WsRequest {
                        id: "req-session-archive".into(),
                        method: ws_methods::SESSION_ARCHIVE.into(),
                        params: serde_json::json!({
                            "session_id": session_id,
                            "actor": "spoofed-client",
                        }),
                        trace_context: None,
                    };

                    let response = dispatch(&request, &state, &connection).await;

                    assert!(response.error.is_none());
                    assert_eq!(
                        response
                            .result
                            .as_ref()
                            .and_then(|result| result["session_id"].as_str()),
                        Some(session_id)
                    );
                    assert!(
                        response
                            .result
                            .as_ref()
                            .and_then(|result| result["archived_at"].as_str())
                            .is_some()
                    );

                    let async_db = state.async_db.get().expect("async db");
                    assert!(
                        async_db
                            .resolve_session(session_id)
                            .await
                            .expect("resolve archived session")
                            .is_none()
                    );
                });
            },
        );
    });
}

#[test]
fn websocket_async_signal_ack_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                (
                    "CLAUDE_SESSION_ID",
                    Some("2871f53d-350f-581f-972e-f6d16f5e1526-leader"),
                ),
                (
                    "CODEX_SESSION_ID",
                    Some("2871f53d-350f-581f-972e-f6d16f5e1526-worker"),
                ),
            ],
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    start_async_session(
                        &state,
                        &project_dir,
                        "2871f53d-350f-581f-972e-f6d16f5e1526",
                    )
                    .await;
                    let worker_id = join_async_worker(
                        &state,
                        "2871f53d-350f-581f-972e-f6d16f5e1526",
                        &project_dir,
                        "Async WS Signal Ack Worker",
                    )
                    .await;
                    let leader_id =
                        leader_id_for_session(&state, "2871f53d-350f-581f-972e-f6d16f5e1526").await;
                    let signal_id = seed_pending_signal(
                        &state,
                        "2871f53d-350f-581f-972e-f6d16f5e1526",
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
                            "session_id": "2871f53d-350f-581f-972e-f6d16f5e1526",
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
                            .load_signals("2871f53d-350f-581f-972e-f6d16f5e1526")
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
                "managed_agent_id": "missing-agent",
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
fn websocket_managed_agent_sequence_errors_include_http_status_metadata() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let request = WsRequest {
            id: "req-managed-agent-sequence-missing".into(),
            method: ws_methods::MANAGED_AGENT_INPUT.into(),
            params: serde_json::json!({
                "managed_agent_id": "missing-agent",
                "sequence": {
                    "steps": [
                        {
                            "delay_before_ms": 0,
                            "input": {
                                "type": "text",
                                "text": "hello"
                            }
                        }
                    ]
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
