use axum::http::HeaderValue;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use super::{StatusCode, Value, http_paths, json};

pub(super) fn normalized_running_review(value: &Value) -> Value {
    let mut normalized = value.clone();
    normalized["execution_id"] = json!("execution");
    normalized
}

pub(super) fn normalized_review(value: &Value) -> Value {
    let mut normalized = value.clone();
    normalized["report"]["report_id"] = json!("report");
    normalized["report"]["item_id"] = json!("item");
    normalized["report"]["correlation_id"] = json!("correlation");
    normalized
}

pub(super) async fn serve_http(
    state: crate::daemon::http::DaemonHttpState,
) -> (String, JoinHandle<()>) {
    let app = crate::daemon::http::daemon_http_router(state);
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

pub(super) async fn delete_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
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

pub(super) async fn get_json_status(
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

pub(super) async fn ws_rpc(base_url: &str, id: &str, method: &str, params: Value) -> Value {
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

pub(super) async fn ws_result(base_url: &str, id: &str, method: &str, params: Value) -> Value {
    let response = ws_rpc(base_url, id, method, params).await;
    assert_eq!(
        response["error"],
        Value::Null,
        "{method} returned {response}"
    );
    response["result"].clone()
}

pub(super) fn normalized_item(item: &Value) -> Value {
    let mut item = item.clone();
    item["id"] = json!("<id>");
    item["created_at"] = json!("<created_at>");
    item["updated_at"] = json!("<updated_at>");
    // Triage ranks each new item against the lane it lands in, so the second
    // item created here necessarily gets the later slot. That is board state,
    // not a transport difference, and comparing it would only assert the order
    // this test creates its two items in.
    if item.get("lane_position").is_some() {
        item["lane_position"] = json!("<lane_position>");
    }
    if item.get("lane_set_at").is_some() {
        item["lane_set_at"] = json!("<lane_set_at>");
    }
    if item.get("deleted_at").is_some() {
        item["deleted_at"] = json!("<deleted_at>");
    }
    // Each item owns its own work item, so the two differ by construction.
    if item.get("work_item_id").is_some() {
        item["work_item_id"] = json!("<work_item_id>");
    }
    item
}
