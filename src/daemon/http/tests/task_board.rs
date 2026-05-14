use std::path::Path;

use reqwest::StatusCode;
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::protocol::SessionJoinRequest;
use crate::daemon::protocol::http_paths;
use crate::daemon::service::join_session_direct_async;
use crate::session::types::SessionRole;
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardStore, default_board_root};

use super::*;

#[test]
fn task_board_http_dispatch_evaluate_and_run_once_use_real_state() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_http_flow(sandbox.path()));
    });
}

async fn run_task_board_http_flow(sandbox: &Path) {
    let project_dir = sandbox.join("project");
    harness_testkit::init_git_repo_with_seed(&project_dir);
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    seed_ready_board_item("board-http-dispatch", "HTTP dispatch item");
    let dispatch = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_DISPATCH,
        json!({
            "status": "todo",
            "dry_run": false,
            "project_dir": project_dir,
        }),
    )
    .await;
    let applied = first_applied(&dispatch);
    let session_id = required_string(applied, "session_id");
    let work_item_id = required_string(applied, "work_item_id");
    assert_eq!(applied["item"]["status"].as_str(), Some("in_progress"));
    assert_eq!(
        applied["item"]["workflow"]["status"].as_str(),
        Some("running")
    );
    join_leader(&state, &session_id, &project_dir).await;

    post_json(
        &client,
        &base_url,
        &format!("/v1/sessions/{session_id}/tasks/{work_item_id}/status"),
        json!({
            "actor": "spoofed-client",
            "status": "done",
            "note": "completed by test"
        }),
    )
    .await;
    let evaluation = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_EVALUATE,
        json!({
            "status": "in_progress",
            "dry_run": false,
        }),
    )
    .await;
    assert_eq!(evaluation["updated"].as_u64(), Some(1));
    assert_eq!(evaluation["completed"].as_u64(), Some(1));
    assert_eq!(
        evaluation["records"][0]["item"]["workflow"]["status"].as_str(),
        Some("completed")
    );

    seed_ready_board_item("board-http-run-once", "HTTP run once item");
    let run_once = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        json!({
            "status": "todo",
            "dry_run": false,
            "project_dir": project_dir,
        }),
    )
    .await;
    assert_eq!(run_once["last_run"]["status"].as_str(), Some("completed"));
    assert_eq!(
        run_once["last_run"]["dispatch"]["applied"]
            .as_array()
            .map(Vec::len),
        Some(1)
    );
    assert!(
        run_once["last_run"]["evaluation"]["evaluated"]
            .as_u64()
            .is_some_and(|count| count >= 1)
    );
    assert!(evaluation_records_contain(&run_once, "board-http-run-once"));
    assert!(
        run_once["last_run"]["policy_trace_ids"]
            .as_array()
            .is_some_and(|trace_ids| !trace_ids.is_empty())
    );

    server.abort();
    let _ = server.await;
}

async fn join_leader(
    state: &crate::daemon::http::DaemonHttpState,
    session_id: &str,
    project_dir: &Path,
) {
    let async_db = state.async_db.get().expect("async db");
    join_session_direct_async(
        session_id,
        &SessionJoinRequest {
            runtime: "claude".into(),
            role: SessionRole::Leader,
            fallback_role: None,
            capabilities: Vec::new(),
            name: Some("leader".into()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            persona: None,
        },
        async_db.as_ref(),
    )
    .await
    .expect("join leader");
}

async fn serve_http(state: crate::daemon::http::DaemonHttpState) -> (String, JoinHandle<()>) {
    let app = super::super::daemon_http_router().with_state(state);
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });
    (format!("http://{addr}"), server)
}

async fn post_json(client: &reqwest::Client, base_url: &str, path: &str, body: Value) -> Value {
    let response = client
        .post(format!("{base_url}{path}"))
        .bearer_auth("token")
        .json(&body)
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    assert_eq!(status, StatusCode::OK, "{path} returned {value}");
    value
}

fn seed_ready_board_item(id: &str, title: &str) {
    let store = TaskBoardStore::new(default_board_root());
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a daemon integration task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Todo;
    let item = submit_plan(&item, "Use task dispatch.").apply_to(&item);
    let item = approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item);
    let title = item.title.clone();
    let body = item.body.clone();
    store.create(&title, &body, item).expect("create item");
}

fn first_applied(value: &Value) -> &Value {
    value["applied"]
        .as_array()
        .and_then(|applied| applied.first())
        .expect("first applied task")
}

fn required_string(value: &Value, key: &str) -> String {
    value[key].as_str().expect("string field").to_string()
}

fn evaluation_records_contain(value: &Value, board_item_id: &str) -> bool {
    value["last_run"]["evaluation"]["records"]
        .as_array()
        .is_some_and(|records| {
            records
                .iter()
                .any(|record| record["board_item_id"].as_str() == Some(board_item_id))
        })
}
