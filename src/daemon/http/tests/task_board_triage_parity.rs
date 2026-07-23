use reqwest::StatusCode;
use serde_json::json;
use tempfile::tempdir;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

use super::task_board_route_parity_support::{serve_http, ws_rpc};

#[test]
fn task_board_triage_current_has_no_decision_for_a_fresh_item() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_triage_current_empty_for_fresh_item());
    });
}

#[test]
fn task_board_triage_history_has_http_websocket_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_triage_history_parity());
    });
}

#[test]
fn task_board_triage_history_rejects_invalid_pagination_with_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_invalid_triage_history_pagination_parity());
    });
}

#[test]
fn task_board_triage_invalid_id_has_http_websocket_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_invalid_triage_id_parity());
    });
}

async fn assert_triage_current_empty_for_fresh_item() {
    let state = super::test_http_state_with_db();
    let db = state.async_db.get().expect("async db").clone();
    db.create_task_board_item(TaskBoardItem::new(
        "triage-fresh".into(),
        "Triage fresh".into(),
        "No decision yet.".into(),
        "2026-07-23T00:00:00Z".into(),
    ))
    .await
    .expect("create item");
    let path = http_paths::TASK_BOARD_ITEM_TRIAGE.replace("{item_id}", "triage-fresh");
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let http_response = client
        .get(format!("{base_url}{path}"))
        .bearer_auth("token")
        .send()
        .await
        .expect("send HTTP triage current request");
    assert_eq!(http_response.status(), StatusCode::OK);
    let http_body = http_response
        .json::<serde_json::Value>()
        .await
        .expect("HTTP triage current body");
    assert_eq!(http_body["current"], serde_json::Value::Null);

    let websocket = ws_rpc(
        &base_url,
        "triage-fresh-ws",
        ws_methods::TASK_BOARD_TRIAGE_GET,
        json!({ "id": "triage-fresh" }),
    )
    .await;
    assert_eq!(websocket["result"], http_body);

    server.abort();
    let _ = server.await;
}

async fn assert_triage_history_parity() {
    let state = super::test_http_state_with_db();
    let mut item = TaskBoardItem::new(
        "triage-history".into(),
        "Triage history".into(),
        "Has an initial decision.".into(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    let db = state.async_db.get().expect("async db").clone();
    db.create_task_board_item_with_triage(item)
        .await
        .expect("create item with triage");
    let path = http_paths::TASK_BOARD_ITEM_TRIAGE_HISTORY.replace("{item_id}", "triage-history");
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let http_response = client
        .get(format!("{base_url}{path}?limit=50"))
        .bearer_auth("token")
        .send()
        .await
        .expect("send HTTP triage history request");
    assert_eq!(http_response.status(), StatusCode::OK);
    let http_body = http_response
        .json::<serde_json::Value>()
        .await
        .expect("HTTP triage history body");
    let decisions = http_body["decisions"].as_array().expect("decisions array");
    assert_eq!(decisions.len(), 1);
    assert_eq!(decisions[0]["item_id"], "triage-history");
    assert_eq!(http_body["next_before_generation"], serde_json::Value::Null);

    let websocket = ws_rpc(
        &base_url,
        "triage-history-ws",
        ws_methods::TASK_BOARD_TRIAGE_HISTORY,
        json!({ "id": "triage-history", "limit": 50 }),
    )
    .await;
    assert_eq!(websocket["result"], http_body);

    server.abort();
    let _ = server.await;
}

async fn assert_invalid_triage_id_parity() {
    const INVALID_ID: &str = "unsafe..triage";
    let state = super::test_http_state_with_db();
    let current_path = http_paths::TASK_BOARD_ITEM_TRIAGE.replace("{item_id}", INVALID_ID);
    let history_path = http_paths::TASK_BOARD_ITEM_TRIAGE_HISTORY.replace("{item_id}", INVALID_ID);
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    assert_invalid_triage_id_response(
        client
            .get(format!("{base_url}{current_path}"))
            .bearer_auth("token")
            .send()
            .await
            .expect("send HTTP triage current get"),
        &base_url,
        "triage-invalid-current",
        ws_methods::TASK_BOARD_TRIAGE_GET,
        json!({ "id": INVALID_ID }),
    )
    .await;

    assert_invalid_triage_id_response(
        client
            .get(format!("{base_url}{history_path}"))
            .bearer_auth("token")
            .send()
            .await
            .expect("send HTTP triage history get"),
        &base_url,
        "triage-invalid-history",
        ws_methods::TASK_BOARD_TRIAGE_HISTORY,
        json!({ "id": INVALID_ID }),
    )
    .await;

    server.abort();
    let _ = server.await;
}

async fn assert_invalid_triage_id_response(
    response: reqwest::Response,
    base_url: &str,
    request_id: &str,
    method: &str,
    params: serde_json::Value,
) {
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let http_body = response
        .json::<serde_json::Value>()
        .await
        .expect("HTTP error body");
    let websocket = ws_rpc(base_url, request_id, method, params).await;
    let websocket_error = &websocket["error"];
    assert_eq!(websocket_error["code"], http_body["error"]["code"]);
    assert_eq!(websocket_error["status_code"], 400);
    assert_eq!(websocket_error["data"], http_body);
}

async fn assert_invalid_triage_history_pagination_parity() {
    let state = super::test_http_state_with_db();
    let path = http_paths::TASK_BOARD_ITEM_TRIAGE_HISTORY.replace("{item_id}", "triage-invalid");
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let cases = [
        ("limit=0", json!({ "id": "triage-invalid", "limit": 0 })),
        ("limit=101", json!({ "id": "triage-invalid", "limit": 101 })),
        (
            "before_generation=0",
            json!({ "id": "triage-invalid", "before_generation": 0 }),
        ),
        (
            "before_generation=not-a-number",
            json!({ "id": "triage-invalid", "before_generation": "not-a-number" }),
        ),
        (
            "limit=not-a-number",
            json!({ "id": "triage-invalid", "limit": "not-a-number" }),
        ),
    ];

    for (index, (query, params)) in cases.into_iter().enumerate() {
        let response = client
            .get(format!("{base_url}{path}?{query}"))
            .bearer_auth("token")
            .send()
            .await
            .expect("send invalid HTTP triage history request");
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{query}");
        let http_body = response
            .json::<serde_json::Value>()
            .await
            .expect("invalid HTTP triage history body");
        let websocket = ws_rpc(
            &base_url,
            &format!("triage-invalid-page-{index}"),
            ws_methods::TASK_BOARD_TRIAGE_HISTORY,
            params,
        )
        .await;
        let websocket_error = &websocket["error"];
        assert_eq!(
            websocket_error["code"], http_body["error"]["code"],
            "{query}"
        );
        assert_eq!(websocket_error["status_code"], 400, "{query}");
        assert_eq!(websocket_error["data"], http_body, "{query}");
    }

    server.abort();
    let _ = server.await;
}
