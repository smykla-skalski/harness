use axum::http::HeaderValue;
use chrono::{DateTime, Utc};
use futures_util::{SinkExt, StreamExt};
use reqwest::StatusCode;
use serde_json::{Value, json};
use sqlx::query;
use tempfile::tempdir;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{http_paths, ws_methods};

use super::task_board_route_parity_support::{get_json, serve_http, ws_result};

#[test]
fn automation_observability_http_and_websocket_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_route_parity());
    });
}

async fn run_route_parity() {
    let state = super::test_http_state_with_db();
    seed_terminal_run(
        state.async_db.get().expect("test async database"),
        "automation-route-run",
    )
    .await;
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    assert_history_parity(&client, &base_url).await;
    assert_detail_parity(&client, &base_url).await;
    assert_metrics_parity(&client, &base_url).await;
    assert_missing_detail_parity(&client, &base_url).await;

    server.abort();
    let _ = server.await;
}

async fn assert_history_parity(client: &reqwest::Client, base_url: &str) {
    let http = get_json(
        client,
        base_url,
        &format!("{}?limit=10", http_paths::TASK_BOARD_ORCHESTRATOR_RUNS),
    )
    .await;
    let websocket = ws_result(
        base_url,
        "automation-runs",
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
        json!({ "limit": 10 }),
    )
    .await;
    assert_eq!(http, websocket);
    assert_eq!(http["runs"][0]["run_id"], "automation-route-run");

    let default_http = get_json(client, base_url, http_paths::TASK_BOARD_ORCHESTRATOR_RUNS).await;
    let null_websocket = ws_result(
        base_url,
        "automation-runs-null-params",
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
        Value::Null,
    )
    .await;
    assert_eq!(default_http, null_websocket);

    let omitted_websocket = ws_rpc_without_params(
        base_url,
        "automation-runs-omitted-params",
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
    )
    .await;
    assert_eq!(omitted_websocket["error"], Value::Null);
    assert_eq!(default_http, omitted_websocket["result"]);
}

async fn assert_detail_parity(client: &reqwest::Client, base_url: &str) {
    let detail_path = detail_path("automation-route-run");
    let http = get_json(client, base_url, &detail_path).await;
    let websocket = ws_result(
        base_url,
        "automation-run-detail",
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
        json!({ "run_id": "automation-route-run" }),
    )
    .await;
    assert_eq!(http, websocket);
}

async fn assert_metrics_parity(client: &reqwest::Client, base_url: &str) {
    let http = get_json(
        client,
        base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_METRICS,
    )
    .await;
    let websocket = ws_result(
        base_url,
        "automation-metrics",
        ws_methods::TASK_BOARD_ORCHESTRATOR_METRICS,
        json!({}),
    )
    .await;
    assert_eq!(without_capture_time(http), without_capture_time(websocket));
}

async fn assert_missing_detail_parity(client: &reqwest::Client, base_url: &str) {
    let (http_status, http_error) =
        get_json_status(client, base_url, &detail_path("missing-run")).await;
    let websocket = ws_rpc(
        base_url,
        "missing-automation-run",
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
        json!({ "run_id": "missing-run" }),
    )
    .await;

    assert_eq!(http_status, StatusCode::BAD_REQUEST);
    assert_eq!(websocket["error"]["status_code"].as_u64(), Some(400));
    assert_eq!(websocket["error"]["code"], http_error["error"]["code"]);
    assert_eq!(
        websocket["error"]["message"],
        http_error["error"]["message"]
    );
    assert_eq!(websocket["error"]["data"], http_error);
}

async fn seed_terminal_run(db: &AsyncDaemonDb, run_id: &str) {
    let at = instant("2026-07-15T12:00:00Z").to_rfc3339();
    query(
        "INSERT INTO task_board_orchestrator_runs (
            run_id, trigger, actor, dry_run, scope_json, state, outcome,
            lease_owner, lease_epoch, lease_expires_at, stop_generation,
            started_at, heartbeat_at, completed_at, stage_summary_json, revision
         ) VALUES (?1, 'manual', 'operator', 0, '{}', 'terminal', 'completed',
                   'route-test', 1, ?2, 0, ?2, ?2, ?2, '{}', 1)",
    )
    .bind(run_id)
    .bind(at)
    .execute(db.pool())
    .await
    .expect("seed terminal automation run");
}

fn detail_path(run_id: &str) -> String {
    http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL.replace("{run_id}", run_id)
}

fn without_capture_time(mut value: Value) -> Value {
    value
        .as_object_mut()
        .expect("metrics object")
        .remove("captured_at");
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
    ws_rpc_request(
        base_url,
        json!({ "id": id, "method": method, "params": params }),
    )
    .await
}

async fn ws_rpc_without_params(base_url: &str, id: &str, method: &str) -> Value {
    ws_rpc_request(base_url, json!({ "id": id, "method": method })).await
}

async fn ws_rpc_request(base_url: &str, request_body: Value) -> Value {
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
        .send(Message::Text(request_body.to_string().into()))
        .await
        .expect("send websocket frame");
    let id = request_body["id"].as_str().expect("request id");
    while let Some(frame) = socket.next().await {
        let text = frame
            .expect("read websocket frame")
            .into_text()
            .expect("text frame");
        let value = serde_json::from_str::<Value>(&text).expect("websocket JSON");
        if value["id"].as_str() == Some(id) {
            let _ = socket.close(None).await;
            return value;
        }
    }
    panic!("missing websocket response for {id}");
}

fn instant(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("valid instant")
        .with_timezone(&Utc)
}
