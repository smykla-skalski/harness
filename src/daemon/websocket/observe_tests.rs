use std::sync::{Arc, Mutex};

use fs_err as fs;
use tempfile::tempdir;

use super::connection::ConnectionState;
use super::dispatch::dispatch;
use super::tests::{
    init_git_project, join_async_worker, leader_id_for_session, start_async_session,
    test_websocket_state_with_empty_async_db,
};
use crate::daemon::protocol::WsRequest;
use crate::workspace::project_context_dir;
use harness_testkit::with_isolated_harness_env;

fn append_project_ledger_entry(project_dir: &std::path::Path) {
    let ledger_path = project_context_dir(project_dir)
        .join("agents")
        .join("ledger")
        .join("events.jsonl");
    fs::create_dir_all(ledger_path.parent().expect("ledger dir")).expect("create ledger dir");
    fs::write(
        &ledger_path,
        format!(
            "{{\"sequence\":1,\"recorded_at\":\"2026-03-28T12:00:00Z\",\"cwd\":\"{}\"}}\n",
            project_dir.display()
        ),
    )
    .expect("write ledger");
}

fn write_agent_log(project_dir: &std::path::Path, runtime: &str, session_id: &str, text: &str) {
    let log_path = project_context_dir(project_dir)
        .join("agents/sessions")
        .join(runtime)
        .join(session_id)
        .join("raw.jsonl");
    fs::create_dir_all(log_path.parent().expect("log dir")).expect("create log dir");
    fs::write(
        log_path,
        format!(
            "{{\"timestamp\":\"2026-03-28T12:00:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"{text}\"}}}}\n"
        ),
    )
    .expect("write log");
}

async fn agent_runtime_session_id_for_agent(
    state: &crate::daemon::http::DaemonHttpState,
    session_id: &str,
    agent_id: &str,
) -> String {
    let async_db = state.async_db.get().expect("async db");
    let resolved = async_db
        .resolve_session(session_id)
        .await
        .expect("resolve session")
        .expect("session present");
    resolved
        .state
        .agents
        .get(agent_id)
        .and_then(|agent| agent.agent_session_id.clone())
        .expect("agent runtime session id")
}

#[test]
fn websocket_async_session_observe_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("ws-async-observe-leader")),
                ("CODEX_SESSION_ID", Some("ws-async-observe-worker")),
            ],
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    start_async_session(&state, &project_dir, "ws-async-observe").await;
                    let leader_id = leader_id_for_session(&state, "ws-async-observe").await;
                    let worker_id = join_async_worker(
                        &state,
                        "ws-async-observe",
                        &project_dir,
                        "Async Observe Worker",
                    )
                    .await;
                    let worker_session_id =
                        agent_runtime_session_id_for_agent(&state, "ws-async-observe", &worker_id)
                            .await;
                    append_project_ledger_entry(&project_dir);
                    write_agent_log(
                        &project_dir,
                        "codex",
                        &worker_session_id,
                        "This is a harness infrastructure issue - the KDS port wasn't forwarded",
                    );

                    let connection = Arc::new(Mutex::new(ConnectionState::new()));
                    let request = WsRequest {
                        id: "req-session-observe-async".into(),
                        method: "session.observe".into(),
                        params: serde_json::json!({
                            "session_id": "ws-async-observe",
                            "actor": leader_id.clone()
                        }),
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
                });
            },
        );
    });
}
