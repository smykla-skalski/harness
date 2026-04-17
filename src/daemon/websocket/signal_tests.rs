use std::sync::{Arc, Mutex};

use tempfile::tempdir;

use super::connection::ConnectionState;
use super::dispatch::dispatch;
use super::tests::{
    init_git_project, join_async_worker, leader_id_for_session, start_async_session,
    test_websocket_state_with_empty_async_db,
};
use crate::daemon::protocol::WsRequest;
use harness_testkit::with_isolated_harness_env;

#[test]
fn websocket_async_signal_send_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("ws-async-signal-send-leader")),
                ("CODEX_SESSION_ID", Some("ws-async-signal-send-worker")),
            ],
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    start_async_session(&state, &project_dir, "ws-async-signal-send").await;
                    let worker_id = join_async_worker(
                        &state,
                        "ws-async-signal-send",
                        &project_dir,
                        "Async Signal Worker",
                    )
                    .await;
                    let leader_id = leader_id_for_session(&state, "ws-async-signal-send").await;
                    let connection = Arc::new(Mutex::new(ConnectionState::new()));
                    let request = WsRequest {
                        id: "req-signal-send-async".into(),
                        method: "signal.send".into(),
                        params: serde_json::json!({
                            "session_id": "ws-async-signal-send",
                            "actor": leader_id,
                            "agent_id": worker_id.clone(),
                            "command": "inject_context",
                            "message": "async websocket signal",
                            "action_hint": "task:ws-async-signal"
                        }),
                        trace_context: None,
                    };

                    let response = dispatch(&request, &state, &connection).await;

                    assert!(response.error.is_none());
                    let signal = response
                        .result
                        .as_ref()
                        .and_then(|result| result["signals"].as_array())
                        .and_then(|signals| signals.first())
                        .expect("signal response");
                    assert_eq!(signal["agent_id"].as_str(), Some(worker_id.as_str()));
                    assert_eq!(signal["status"].as_str(), Some("pending"));
                    assert_eq!(
                        signal["signal"]["payload"]["message"].as_str(),
                        Some("async websocket signal")
                    );
                });
            },
        );
    });
}
