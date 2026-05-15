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

#[test]
fn task_board_http_and_ws_item_payloads_and_errors_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_transport_parity());
    });
}

async fn run_task_board_transport_parity() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let shared_payload = json!({
        "title": "Transport parity item",
        "body": "Shared task-board body",
        "priority": "high",
        "agent_mode": "planning",
        "tags": ["parity"],
        "project_id": "project-alpha",
        "planning": {
            "summary": "Shared planning summary"
        },
        "workflow": {
            "status": "running",
            "branch": "feature/parity"
        }
    });

    let mut http_payload = shared_payload.clone();
    http_payload["id"] = json!("parity-http");
    let http_item = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ITEMS,
        http_payload,
    )
    .await;

    let mut ws_payload = shared_payload;
    ws_payload["id"] = json!("parity-ws");
    let ws_item = ws_rpc(
        &base_url,
        "req-task-board-create",
        ws_methods::TASK_BOARD_CREATE,
        ws_payload,
    )
    .await;

    assert_eq!(
        normalized_item(&http_item),
        normalized_item(&ws_item["result"])
    );

    let http_list = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_ITEMS),
    )
    .await;
    let ws_list = ws_result(
        &base_url,
        "req-task-board-list",
        ws_methods::TASK_BOARD_LIST,
        json!({ "status": "todo" }),
    )
    .await;
    assert_eq!(http_list, ws_list);

    let http_loaded = get_json(&client, &base_url, "/v1/task-board/items/parity-http").await;
    let ws_loaded = ws_result(
        &base_url,
        "req-task-board-get",
        ws_methods::TASK_BOARD_GET,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(normalized_item(&http_loaded), normalized_item(&ws_loaded));

    let update_payload = json!({
        "status": "in_progress",
        "priority": "critical",
        "tags": ["parity", "updated"],
        "clear_planning": true,
        "clear_workflow": true,
    });
    let http_updated = put_json(
        &client,
        &base_url,
        "/v1/task-board/items/parity-http",
        update_payload.clone(),
    )
    .await;
    let mut ws_update_payload = update_payload;
    ws_update_payload["id"] = json!("parity-ws");
    let ws_updated = ws_result(
        &base_url,
        "req-task-board-update",
        ws_methods::TASK_BOARD_UPDATE,
        ws_update_payload,
    )
    .await;
    assert_eq!(normalized_item(&http_updated), normalized_item(&ws_updated));
    assert_eq!(http_updated["planning"], json!({}));
    assert!(http_updated.get("workflow").is_none());
    assert_eq!(ws_updated["planning"], json!({}));
    assert!(ws_updated.get("workflow").is_none());

    let http_deleted = delete_json(&client, &base_url, "/v1/task-board/items/parity-http").await;
    let ws_deleted = ws_result(
        &base_url,
        "req-task-board-delete",
        ws_methods::TASK_BOARD_DELETE,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(normalized_item(&http_deleted), normalized_item(&ws_deleted));

    let (http_status, http_error) =
        get_json_status(&client, &base_url, "/v1/task-board/items/parity-missing").await;
    let ws_error = ws_rpc(
        &base_url,
        "req-task-board-missing",
        ws_methods::TASK_BOARD_GET,
        json!({ "id": "parity-missing" }),
    )
    .await;

    assert_eq!(http_status, StatusCode::BAD_REQUEST);
    assert_eq!(ws_error["error"]["status_code"].as_u64(), Some(400));
    assert_eq!(ws_error["error"]["code"], http_error["error"]["code"]);
    assert_eq!(ws_error["error"]["message"], http_error["error"]["message"]);
    assert_eq!(ws_error["error"]["data"], http_error);

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

async fn put_json(client: &reqwest::Client, base_url: &str, path: &str, body: Value) -> Value {
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

async fn delete_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
    let response = client
        .delete(format!("{base_url}{path}"))
        .bearer_auth("token")
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    assert_eq!(status, StatusCode::OK, "{path} returned {value}");
    value
}

async fn get_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
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

async fn get_json_status(
    client: &reqwest::Client,
    base_url: &str,
    path: &str,
) -> (StatusCode, Value) {
    let response = client
        .get(format!("{base_url}{path}"))
        .bearer_auth("token")
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    (status, value)
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
    let frame = json!({
        "id": id,
        "method": method,
        "params": params,
    });
    socket
        .send(Message::Text(frame.to_string().into()))
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

async fn ws_result(base_url: &str, id: &str, method: &str, params: Value) -> Value {
    let response = ws_rpc(base_url, id, method, params).await;
    assert_eq!(
        response["error"],
        Value::Null,
        "{method} returned {response}"
    );
    response["result"].clone()
}

fn normalized_item(item: &Value) -> Value {
    let mut item = item.clone();
    item["id"] = json!("<id>");
    item["created_at"] = json!("<created_at>");
    item["updated_at"] = json!("<updated_at>");
    if item.get("deleted_at").is_some() {
        item["deleted_at"] = json!("<deleted_at>");
    }
    item
}
