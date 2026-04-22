use std::sync::{Arc, Mutex};

use tempfile::tempdir;

use super::connection::ConnectionState;
use super::dispatch::dispatch;
use super::tests::{init_git_project, test_websocket_state_with_empty_async_db};
use crate::daemon::protocol::WsRequest;
use harness_testkit::with_isolated_harness_env;

#[test]
fn websocket_async_session_start_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let project_dir = sandbox.path().join("project");
            init_git_project(&project_dir);

            let db_path = sandbox.path().join("daemon.sqlite");
            let state = test_websocket_state_with_empty_async_db(&db_path).await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));
            let mut receiver = state.sender.subscribe();
            let request = WsRequest {
                id: "req-session-start-async".into(),
                method: "session.start".into(),
                params: serde_json::json!({
                    "title": "async websocket session",
                    "context": "prefer sqlx websocket path",
                    "runtime": "claude",
                    "session_id": "ws-session-start-async",
                    "project_dir": project_dir.to_string_lossy().into_owned(),
                }),
                trace_context: None,
            };

            let response = dispatch(&request, &state, &connection).await;

            assert!(response.error.is_none());
            assert_eq!(
                response
                    .result
                    .as_ref()
                    .and_then(|result| result["state"]["session_id"].as_str()),
                Some("ws-session-start-async")
            );
            assert_eq!(
                response
                    .result
                    .as_ref()
                    .and_then(|result| result["state"]["title"].as_str()),
                Some("async websocket session")
            );
            assert_eq!(
                receiver.recv().await.expect("sessions_updated").event,
                "sessions_updated"
            );
        });
    });
}
