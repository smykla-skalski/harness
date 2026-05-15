use axum::http::HeaderValue;
use futures_util::{SinkExt, StreamExt};
use reqwest::StatusCode;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardStore, default_board_root};

pub(super) async fn serve_http(
    state: crate::daemon::http::DaemonHttpState,
) -> (String, JoinHandle<()>) {
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

pub(super) async fn post_json(
    client: &reqwest::Client,
    base_url: &str,
    path: &str,
    body: Value,
) -> Value {
    json_request(client.post(format!("{base_url}{path}")).json(&body), path).await
}

pub(super) async fn put_json(
    client: &reqwest::Client,
    base_url: &str,
    path: &str,
    body: Value,
) -> Value {
    json_request(client.put(format!("{base_url}{path}")).json(&body), path).await
}

pub(super) async fn get_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
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

pub(super) async fn ws_result(base_url: &str, id: &str, method: &str, params: Value) -> Value {
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

pub(super) async fn assert_http_ws_post_match(
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

pub(super) async fn assert_http_ws_put_match(
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

pub(super) async fn assert_http_ws_get_match(
    client: &reqwest::Client,
    base_url: &str,
    http_path: &str,
    ws_method: &str,
) {
    let http = get_json(client, base_url, http_path).await;
    let ws = ws_result(base_url, &format!("req-{ws_method}"), ws_method, json!({})).await;
    assert_eq!(http, ws);
}

pub(super) async fn assert_run_once_routes_match(client: &reqwest::Client, base_url: &str) {
    seed_ready_board_item("parity-run-once-http", "Run once HTTP parity item");
    let http = post_json(
        client,
        base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        json!({
            "dry_run": true,
            "input": {
                "dispatch_status": "todo",
                "sync_direction": "pull",
                "sync_dry_run": true
            }
        }),
    )
    .await;

    seed_ready_board_item("parity-run-once-ws", "Run once WS parity item");
    let ws = ws_result(
        base_url,
        "req-task-board-orchestrator-run-once",
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        json!({
            "dry_run": true,
            "input": {
                "dispatch_status": "todo",
                "sync_direction": "pull",
                "sync_dry_run": true
            }
        }),
    )
    .await;
    assert_run_once_parity(http, ws);
}

fn assert_run_once_parity(http: Value, ws: Value) {
    assert_eq!(http["dry_run"], ws["dry_run"]);
    assert_eq!(http["sync"]["operations"], ws["sync"]["operations"]);
    assert_eq!(
        http["dispatch"]["plans"].as_array().map(Vec::len),
        ws["dispatch"]["plans"].as_array().map(Vec::len)
    );
    assert_eq!(http["dispatch"]["applied"], ws["dispatch"]["applied"]);
    assert_eq!(http["evaluation"]["updated"], ws["evaluation"]["updated"]);
}

pub(super) async fn assert_settings_routes_match(client: &reqwest::Client, base_url: &str) {
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

pub(super) async fn assert_runtime_config_routes_match(client: &reqwest::Client, base_url: &str) {
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

pub(super) async fn save_simulate_and_promote_http(
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

pub(super) async fn save_simulate_and_promote_ws(base_url: &str, pipeline: &Value) -> Value {
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

pub(super) fn seed_ready_board_item(id: &str, title: &str) {
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

pub(super) fn seed_planning_board_item(id: &str) {
    let store = TaskBoardStore::new(default_board_root());
    let mut item = TaskBoardItem::new(
        id.to_string(),
        "Planning parity item".to_string(),
        "Create a planning parity task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Todo;
    item.planning.summary = Some("Old plan".into());
    item.planning.approved_by = Some("lead".into());
    item.planning.approved_at = Some("2026-05-14T01:00:00Z".into());
    let title = item.title.clone();
    let body = item.body.clone();
    store.create(&title, &body, item).expect("create item");
}

pub(super) fn planning_path(template: &str, id: &str) -> String {
    template.replace("{item_id}", id)
}

pub(super) fn normalized_planning_response(value: &Value) -> Value {
    let mut value = value.clone();
    value["transition"]["board_item_id"] = json!("normalized-item");
    value["item"]["id"] = json!("normalized-item");
    value
}

pub(super) fn normalized_policy(value: &Value) -> Value {
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
