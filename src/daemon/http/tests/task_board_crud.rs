use reqwest::StatusCode;
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::protocol::http_paths;

use super::*;

#[test]
fn task_board_http_crud_sync_audit_and_orchestrator_routes_use_real_state() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_flow());
    });
}

async fn run_flow() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let created = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ITEMS,
        json!({
            "id": "board-http-crud",
            "title": "HTTP CRUD item",
            "body": "Create through HTTP route",
        }),
    )
    .await;
    assert_eq!(created["id"].as_str(), Some("board-http-crud"));

    let updated = put_json(
        &client,
        &base_url,
        "/v1/task-board/items/board-http-crud",
        json!({ "status": "todo", "priority": "high" }),
    )
    .await;
    assert_eq!(updated["status"].as_str(), Some("todo"));
    assert_eq!(
        get_json(&client, &base_url, "/v1/task-board/items/board-http-crud").await["priority"]
            .as_str(),
        Some("high")
    );
    let listed = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_ITEMS),
    )
    .await;
    assert_eq!(listed["items"].as_array().map(Vec::len), Some(1));

    let sync = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_SYNC,
        json!({ "status": "todo", "direction": "push", "dry_run": true }),
    )
    .await;
    assert_eq!(sync["total"].as_u64(), Some(1));
    let (sync_status, sync_error) = post_json_with_status(
        &client,
        &base_url,
        http_paths::TASK_BOARD_SYNC,
        json!({ "provider": "todoist", "direction": "pull", "dry_run": true }),
    )
    .await;
    assert_eq!(sync_status, StatusCode::BAD_REQUEST);
    assert!(
        sync_error["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("external sync token missing"))
    );
    let audit = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_AUDIT),
    )
    .await;
    assert_eq!(audit["total"].as_u64(), Some(1));

    assert_eq!(
        get_json(
            &client,
            &base_url,
            http_paths::TASK_BOARD_ORCHESTRATOR_STATUS
        )
        .await["running"]
            .as_bool(),
        Some(false)
    );
    assert_eq!(
        post_json(
            &client,
            &base_url,
            http_paths::TASK_BOARD_ORCHESTRATOR_START,
            json!({}),
        )
        .await["running"]
            .as_bool(),
        Some(true)
    );
    let settings = put_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        json!({ "dry_run_default": false, "dispatch_status_filter": "todo" }),
    )
    .await;
    assert_eq!(settings["dry_run_default"].as_bool(), Some(false));
    let loaded_settings = get_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
    )
    .await;
    assert_eq!(loaded_settings["dry_run_default"].as_bool(), Some(false));
    assert_eq!(
        post_json(
            &client,
            &base_url,
            http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
            json!({}),
        )
        .await["running"]
            .as_bool(),
        Some(false)
    );

    let deleted = delete_json(&client, &base_url, "/v1/task-board/items/board-http-crud").await;
    assert!(deleted["deleted_at"].as_str().is_some());

    server.abort();
    let _ = server.await;
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
    json_request(client.post(format!("{base_url}{path}")).json(&body), path).await
}

async fn post_json_with_status(
    client: &reqwest::Client,
    base_url: &str,
    path: &str,
    body: Value,
) -> (StatusCode, Value) {
    json_request_with_status(client.post(format!("{base_url}{path}")).json(&body)).await
}

async fn put_json(client: &reqwest::Client, base_url: &str, path: &str, body: Value) -> Value {
    json_request(client.put(format!("{base_url}{path}")).json(&body), path).await
}

async fn get_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
    json_request(client.get(format!("{base_url}{path}")), path).await
}

async fn delete_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
    json_request(client.delete(format!("{base_url}{path}")), path).await
}

async fn json_request(builder: reqwest::RequestBuilder, path: &str) -> Value {
    let (status, value) = json_request_with_status(builder).await;
    assert_eq!(status, StatusCode::OK, "{path} returned {value}");
    value
}

async fn json_request_with_status(builder: reqwest::RequestBuilder) -> (StatusCode, Value) {
    let response = builder
        .bearer_auth("token")
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    (status, value)
}
