use axum::http::HeaderValue;
use futures_util::{SinkExt, StreamExt};
use reqwest::StatusCode;
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardStore, default_board_root};

#[test]
fn task_board_http_and_ws_workflow_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_workflow_parity());
    });
}

async fn run_task_board_workflow_parity() {
    seed_ready_board_item("parity-workflow", "Parity workflow item");
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_SYNC,
        ws_methods::TASK_BOARD_SYNC,
        json!({ "status": "todo", "direction": "push", "dry_run": true }),
    )
    .await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_DISPATCH,
        ws_methods::TASK_BOARD_DISPATCH,
        json!({ "id": "parity-workflow", "status": "todo", "dry_run": true }),
    )
    .await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_EVALUATE,
        ws_methods::TASK_BOARD_EVALUATE,
        json!({ "id": "parity-workflow", "status": "in_progress", "dry_run": true }),
    )
    .await;

    let http_audit = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_AUDIT),
    )
    .await;
    let ws_audit = ws_result(
        &base_url,
        "req-task-board-audit",
        ws_methods::TASK_BOARD_AUDIT,
        json!({ "status": "todo" }),
    )
    .await;
    assert_eq!(http_audit, ws_audit);

    server.abort();
    let _ = server.await;
}

#[test]
fn task_board_http_and_ws_orchestrator_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_orchestrator_parity());
    });
}

async fn run_task_board_orchestrator_parity() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let http_status = get_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
    )
    .await;
    let ws_status = ws_result(
        &base_url,
        "req-task-board-orchestrator-status",
        ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
        json!({}),
    )
    .await;
    assert_eq!(http_status, ws_status);

    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_START,
        ws_methods::TASK_BOARD_ORCHESTRATOR_START,
        json!({}),
    )
    .await;
    assert_settings_routes_match(&client, &base_url).await;
    assert_runtime_config_routes_match(&client, &base_url).await;
    assert_http_ws_put_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS,
        ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
        json!({
            "global_token": "global-token",
            "repository_tokens": [{ "repository": "owner/repo", "token": "repo-token" }],
        }),
    )
    .await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
        ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
        json!({}),
    )
    .await;

    server.abort();
    let _ = server.await;
}

#[test]
fn task_board_http_and_ws_policy_pipeline_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_policy_pipeline_parity());
    });
}

async fn run_task_board_policy_pipeline_parity() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let pipeline = get_json(&client, &base_url, http_paths::TASK_BOARD_POLICY_PIPELINE).await;
    let ws_pipeline = ws_result(
        &base_url,
        "req-task-board-policy-get",
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
        json!({}),
    )
    .await;
    assert_eq!(pipeline, ws_pipeline);

    let http_promote = save_simulate_and_promote_http(&client, &base_url, &pipeline).await;
    let ws_promote = save_simulate_and_promote_ws(&base_url, &pipeline).await;
    assert_eq!(
        normalized_policy(&http_promote),
        normalized_policy(&ws_promote)
    );

    let http_audit = get_json(&client, &base_url, http_paths::TASK_BOARD_POLICY_AUDIT).await;
    let ws_audit = ws_result(
        &base_url,
        "req-task-board-policy-audit",
        ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
        json!({}),
    )
    .await;
    assert_eq!(normalized_policy(&http_audit), normalized_policy(&ws_audit));

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

async fn put_json(client: &reqwest::Client, base_url: &str, path: &str, body: Value) -> Value {
    json_request(client.put(format!("{base_url}{path}")).json(&body), path).await
}

async fn get_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
    json_request(client.get(format!("{base_url}{path}")), path).await
}

async fn json_request(builder: reqwest::RequestBuilder, path: &str) -> Value {
    let response = builder
        .bearer_auth("token")
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    assert_eq!(status, StatusCode::OK, "{path} returned {value}");
    value
}

async fn ws_result(base_url: &str, id: &str, method: &str, params: Value) -> Value {
    let response = ws_rpc(base_url, id, method, params).await;
    assert_eq!(
        response["error"],
        Value::Null,
        "{method} returned {response}"
    );
    response["result"].clone()
}

async fn ws_rpc(base_url: &str, id: &str, method: &str, params: Value) -> Value {
    let ws_url = format!(
        "{}{}",
        base_url.replacen("http://", "ws://", 1),
        http_paths::WS
    );
    let mut request = ws_url.into_client_request().expect("ws request");
    request
        .headers_mut()
        .insert("authorization", HeaderValue::from_static("Bearer token"));
    let (mut socket, _) = connect_async(request).await.expect("connect websocket");
    socket
        .send(Message::Text(
            json!({ "id": id, "method": method, "params": params })
                .to_string()
                .into(),
        ))
        .await
        .expect("send ws frame");
    while let Some(frame) = socket.next().await {
        let text = frame
            .expect("read ws frame")
            .into_text()
            .expect("text frame");
        let value = serde_json::from_str::<Value>(&text).expect("ws json");
        if value["id"].as_str() == Some(id) {
            let _ = socket.close(None).await;
            return value;
        }
    }
    panic!("missing websocket response for {id}");
}

async fn assert_http_ws_post_match(
    client: &reqwest::Client,
    base_url: &str,
    http_path: &str,
    ws_method: &str,
    payload: Value,
) {
    let http = post_json(client, base_url, http_path, payload.clone()).await;
    let ws = ws_result(base_url, &format!("req-{ws_method}"), ws_method, payload).await;
    assert_eq!(http, ws);
}

async fn assert_http_ws_put_match(
    client: &reqwest::Client,
    base_url: &str,
    http_path: &str,
    ws_method: &str,
    payload: Value,
) {
    let http = put_json(client, base_url, http_path, payload.clone()).await;
    let ws = ws_result(base_url, &format!("req-{ws_method}"), ws_method, payload).await;
    assert_eq!(http, ws);
}

async fn assert_settings_routes_match(client: &reqwest::Client, base_url: &str) {
    let payload = json!({ "dry_run_default": false, "dispatch_status_filter": "todo" });
    assert_http_ws_put_match(
        client,
        base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
        payload,
    )
    .await;
    let http = get_json(
        client,
        base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
    )
    .await;
    let ws = ws_result(
        base_url,
        "req-task-board-orchestrator-settings-get",
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
        json!({}),
    )
    .await;
    assert_eq!(http, ws);
}

async fn assert_runtime_config_routes_match(client: &reqwest::Client, base_url: &str) {
    let payload = json!({
        "global": {
            "author_name": "Harness Bot",
            "author_email": "bot@example.com",
            "ssh_key_path": "/tmp/id_ed25519",
        },
        "repository_overrides": [{
            "repository": "owner/repo",
            "profile": { "author_email": "repo@example.com" },
        }],
    });
    assert_http_ws_put_match(
        client,
        base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
        payload,
    )
    .await;
    let http = get_json(
        client,
        base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
    )
    .await;
    let ws = ws_result(
        base_url,
        "req-task-board-orchestrator-runtime-config-get",
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
        json!({}),
    )
    .await;
    assert_eq!(http, ws);
}

async fn save_simulate_and_promote_http(
    client: &reqwest::Client,
    base_url: &str,
    pipeline: &Value,
) -> Value {
    let save = put_json(
        client,
        base_url,
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        json!({ "document": pipeline }),
    )
    .await;
    let simulation = post_json(
        client,
        base_url,
        http_paths::TASK_BOARD_POLICY_SIMULATE,
        json!({ "document": save["document"].clone() }),
    )
    .await;
    assert_eq!(simulation["succeeded"].as_bool(), Some(true));
    post_json(
        client,
        base_url,
        http_paths::TASK_BOARD_POLICY_PROMOTE,
        json!({ "revision": save["document"]["revision"].clone() }),
    )
    .await
}

async fn save_simulate_and_promote_ws(base_url: &str, pipeline: &Value) -> Value {
    let save = ws_result(
        base_url,
        "req-task-board-policy-save",
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT,
        json!({ "document": pipeline }),
    )
    .await;
    let simulation = ws_result(
        base_url,
        "req-task-board-policy-simulate",
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE,
        json!({ "document": save["document"].clone() }),
    )
    .await;
    assert_eq!(simulation["succeeded"].as_bool(), Some(true));
    ws_result(
        base_url,
        "req-task-board-policy-promote",
        ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE,
        json!({ "revision": save["document"]["revision"].clone() }),
    )
    .await
}

fn seed_ready_board_item(id: &str, title: &str) {
    let store = TaskBoardStore::new(default_board_root());
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a parity workflow task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Todo;
    let item = submit_plan(&item, "Use dry-run dispatch.").apply_to(&item);
    let item = approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item);
    let title = item.title.clone();
    let body = item.body.clone();
    store.create(&title, &body, item).expect("create item");
}

fn normalized_policy(value: &Value) -> Value {
    let mut value = value.clone();
    replace_dynamic_policy_fields(&mut value);
    value
}

fn replace_dynamic_policy_fields(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, nested) in map {
                if matches!(
                    key.as_str(),
                    "active_revision"
                        | "latest_trace_id"
                        | "revision"
                        | "simulated_at"
                        | "trace_id"
                ) {
                    *nested = json!("<dynamic>");
                } else {
                    replace_dynamic_policy_fields(nested);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                replace_dynamic_policy_fields(item);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {}
    }
}
