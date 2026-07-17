use std::path::Path;

use reqwest::StatusCode;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::{AgentMode, TaskBoardItem, TaskBoardStatus};

pub(super) fn without_durable_task_board_automation<R>(body: impl FnOnce() -> R) -> R {
    temp_env::with_var(
        crate::feature_flags::TASK_BOARD_AUTOMATION_V2_ENV,
        None::<&str>,
        body,
    )
}

pub(super) async fn assert_task_board_capabilities_match(client: &reqwest::Client, base_url: &str) {
    let capabilities = get_json(client, base_url, http_paths::TASK_BOARD_CAPABILITIES).await;
    assert_eq!(capabilities["storage"], "database");
    assert!(capabilities["revision"].as_i64().is_some());
    assert!(
        capabilities["instance_id"]
            .as_str()
            .is_some_and(|value| value.starts_with("task-board-"))
    );
    let websocket = super::task_board_route_parity_support::ws_result(
        base_url,
        "req-task-board-capabilities",
        ws_methods::TASK_BOARD_CAPABILITIES,
        json!({}),
    )
    .await;
    assert_eq!(capabilities, websocket);
}

pub(super) async fn dispatch_http_item(
    client: &reqwest::Client,
    base_url: &str,
    item_id: &str,
    project_dir: &Path,
) -> Value {
    post_json(
        client,
        base_url,
        http_paths::TASK_BOARD_DISPATCH,
        json!({
            "id": item_id,
            "status": "todo",
            "dry_run": false,
            "project_dir": project_dir,
        }),
    )
    .await
}

pub(super) async fn serve_http(
    state: crate::daemon::http::DaemonHttpState,
) -> (String, JoinHandle<()>) {
    let app = super::super::daemon_http_router(state);
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });
    (format!("http://{addr}"), server)
}

pub(super) async fn post_json(
    client: &reqwest::Client,
    base_url: &str,
    path: &str,
    body: Value,
) -> Value {
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

pub(super) async fn put_json(
    client: &reqwest::Client,
    base_url: &str,
    path: &str,
    body: Value,
) -> Value {
    let response = client
        .put(format!("{base_url}{path}"))
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

pub(super) async fn get_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
    let response = client
        .get(format!("{base_url}{path}"))
        .bearer_auth("token")
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    assert_eq!(status, StatusCode::OK, "{path} returned {value}");
    value
}

pub(super) async fn seed_ready_board_item(
    state: &crate::daemon::http::DaemonHttpState,
    id: &str,
    title: &str,
) {
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a daemon integration task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Todo;
    let item = submit_plan(&item, "Use task dispatch.").apply_to(&item);
    let item = approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item);
    state
        .async_db
        .get()
        .expect("async db")
        .create_task_board_item(item)
        .await
        .expect("create item");
}

pub(super) async fn seed_catalog_board_item(
    state: &crate::daemon::http::DaemonHttpState,
    id: &str,
    title: &str,
    project_id: &str,
    agent_mode: AgentMode,
    status: TaskBoardStatus,
) {
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a daemon catalog task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = status;
    item.project_id = Some(project_id.to_string());
    item.agent_mode = agent_mode;
    state
        .async_db
        .get()
        .expect("async db")
        .create_task_board_item(item)
        .await
        .expect("create item");
}

pub(super) fn assert_project_summary(
    value: &Value,
    project_id: &str,
    item_count: u64,
    ready_count: u64,
) {
    let summary = value
        .as_array()
        .and_then(|projects| {
            projects
                .iter()
                .find(|summary| summary["project_id"].as_str() == Some(project_id))
        })
        .unwrap_or_else(|| panic!("missing project summary {project_id}: {value}"));
    assert_eq!(summary["item_count"].as_u64(), Some(item_count));
    assert_eq!(summary["ready_count"].as_u64(), Some(ready_count));
}

pub(super) fn assert_machine_summary(value: &Value, mode: &str, item_count: u64, ready_count: u64) {
    let summary = value
        .as_array()
        .and_then(|machines| {
            machines
                .iter()
                .find(|summary| summary["mode"].as_str() == Some(mode))
        })
        .unwrap_or_else(|| panic!("missing machine summary {mode}: {value}"));
    assert_eq!(summary["item_count"].as_u64(), Some(item_count));
    assert_eq!(summary["ready_count"].as_u64(), Some(ready_count));
}

pub(super) fn first_applied(value: &Value) -> &Value {
    value["applied"]
        .as_array()
        .and_then(|applied| applied.first())
        .expect("first applied task")
}

pub(super) async fn assert_board_item_unlinked(
    state: &crate::daemon::http::DaemonHttpState,
    id: &str,
) {
    let item = state
        .async_db
        .get()
        .expect("async db")
        .task_board_item(id)
        .await
        .expect("load board item");
    assert_eq!(item.status, TaskBoardStatus::Todo);
    assert!(item.work_item_id.is_none());
}

pub(super) async fn assert_board_item_status(
    state: &crate::daemon::http::DaemonHttpState,
    id: &str,
    status: TaskBoardStatus,
) {
    let item = state
        .async_db
        .get()
        .expect("async db")
        .task_board_item(id)
        .await
        .expect("load board item");
    assert_eq!(item.status, status);
}

pub(super) fn required_string(value: &Value, key: &str) -> String {
    value[key].as_str().expect("string field").to_string()
}

pub(super) fn evaluation_records_contain(value: &Value, board_item_id: &str) -> bool {
    value["last_run"]["evaluation"]["records"]
        .as_array()
        .is_some_and(|records| {
            records
                .iter()
                .any(|record| record["board_item_id"].as_str() == Some(board_item_id))
        })
}
