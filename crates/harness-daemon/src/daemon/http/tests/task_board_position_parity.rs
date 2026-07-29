use reqwest::StatusCode;
use serde_json::json;
use tempfile::tempdir;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

use super::task_board_route_parity_support::{serve_http, ws_rpc};

#[test]
fn task_board_position_stale_cas_has_http_websocket_conflict_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_stale_position_cas_parity());
    });
}

#[test]
fn task_board_position_default_reset_has_http_websocket_bad_request_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_default_position_reset_parity());
    });
}

#[test]
fn task_board_position_invalid_id_has_http_websocket_parity_without_writes() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_invalid_position_id_parity_without_writes());
    });
}

async fn assert_stale_position_cas_parity() {
    let state = super::test_http_state_with_db();
    let mut item = TaskBoardItem::new(
        "position-stale".into(),
        "Position stale".into(),
        "Verify position CAS errors.".into(),
        "2026-07-22T14:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    let db = state.async_db.get().expect("async db");
    db.create_task_board_item(item).await.expect("create item");
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    let revision = snapshot
        .items
        .iter()
        .find(|entry| entry.item.id == "position-stale")
        .map(|entry| entry.item_revision)
        .expect("position item revision");
    let stale_revision = revision
        .checked_sub(1)
        .expect("created item revision is positive");
    let path = http_paths::TASK_BOARD_ITEM_POSITION.replace("{item_id}", "position-stale");
    let payload = json!({
        "status": "todo",
        "lane_position": 0,
        "expected_item_revision": stale_revision,
        "expected_items_change_seq": snapshot.items_change_seq,
        "actor": "attacker",
    });
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let http_response = client
        .put(format!("{base_url}{path}"))
        .bearer_auth("token")
        .json(&payload)
        .send()
        .await
        .expect("send HTTP position request");
    assert_eq!(http_response.status(), StatusCode::CONFLICT);
    let http_body = http_response
        .json::<serde_json::Value>()
        .await
        .expect("HTTP error body");
    assert_eq!(http_body["error"]["code"], "WORKFLOW_CONCURRENT");

    let mut websocket_payload = payload.clone();
    websocket_payload["id"] = json!("position-stale");
    let websocket = ws_rpc(
        &base_url,
        "position-stale-ws",
        ws_methods::TASK_BOARD_POSITION_SET,
        websocket_payload,
    )
    .await;
    let websocket_error = &websocket["error"];
    assert_eq!(websocket_error["code"], "WORKFLOW_CONCURRENT");
    assert_eq!(websocket_error["status_code"], 409);
    assert_eq!(websocket_error["data"], http_body);

    server.abort();
    let _ = server.await;
}

async fn assert_default_position_reset_parity() {
    let state = super::test_http_state_with_db();
    let item = TaskBoardItem::new(
        "position-default".into(),
        "Position default".into(),
        "Verify explicit placement state errors.".into(),
        "2026-07-22T14:00:00Z".into(),
    );
    let db = state.async_db.get().expect("async db");
    db.create_task_board_item(item).await.expect("create item");
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    let revision = snapshot
        .items
        .iter()
        .find(|entry| entry.item.id == "position-default")
        .map(|entry| entry.item_revision)
        .expect("position item revision");
    let path = http_paths::TASK_BOARD_ITEM_POSITION_RESET.replace("{item_id}", "position-default");
    let payload = json!({
        "expected_item_revision": revision,
        "expected_items_change_seq": snapshot.items_change_seq,
        "actor": "attacker",
    });
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let http_response = client
        .post(format!("{base_url}{path}"))
        .bearer_auth("token")
        .json(&payload)
        .send()
        .await
        .expect("send HTTP reset request");
    assert_eq!(http_response.status(), StatusCode::BAD_REQUEST);
    let http_body = http_response
        .json::<serde_json::Value>()
        .await
        .expect("HTTP error body");
    assert_eq!(http_body["error"]["code"], "KSRCLI084");

    let mut websocket_payload = payload.clone();
    websocket_payload["id"] = json!("position-default");
    let websocket = ws_rpc(
        &base_url,
        "position-default-ws",
        ws_methods::TASK_BOARD_POSITION_RESET,
        websocket_payload,
    )
    .await;
    let websocket_error = &websocket["error"];
    assert_eq!(websocket_error["code"], "KSRCLI084");
    assert_eq!(websocket_error["status_code"], 400);
    assert_eq!(websocket_error["data"], http_body);

    server.abort();
    let _ = server.await;
}

async fn assert_invalid_position_id_parity_without_writes() {
    const INVALID_ID: &str = "unsafe..position";
    let state = super::test_http_state_with_db();
    let db = state.async_db.get().expect("async db").clone();
    db.create_task_board_item(TaskBoardItem::new(
        "position-safe".into(),
        "Position safe".into(),
        "Verify invalid positions make no mutation.".into(),
        "2026-07-22T14:00:00Z".into(),
    ))
    .await
    .expect("create item");
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    let position_path = http_paths::TASK_BOARD_ITEM_POSITION.replace("{item_id}", INVALID_ID);
    let reset_path = http_paths::TASK_BOARD_ITEM_POSITION_RESET.replace("{item_id}", INVALID_ID);
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    assert_invalid_position_id_response(
        client
            .get(format!("{base_url}{position_path}"))
            .bearer_auth("token")
            .send()
            .await
            .expect("send HTTP position get"),
        &base_url,
        "position-invalid-get",
        ws_methods::TASK_BOARD_POSITION_GET,
        json!({ "id": INVALID_ID }),
    )
    .await;
    let set = json!({
        "status": "todo",
        "lane_position": 0,
        "expected_item_revision": 1,
        "expected_items_change_seq": before.items_change_seq,
        "actor": "attacker",
    });
    assert_invalid_position_id_response(
        client
            .put(format!("{base_url}{position_path}"))
            .bearer_auth("token")
            .json(&set)
            .send()
            .await
            .expect("send HTTP position set"),
        &base_url,
        "position-invalid-set",
        ws_methods::TASK_BOARD_POSITION_SET,
        with_id(set, INVALID_ID),
    )
    .await;
    let reset = json!({
        "expected_item_revision": 1,
        "expected_items_change_seq": before.items_change_seq,
        "actor": "attacker",
    });
    assert_invalid_position_id_response(
        client
            .post(format!("{base_url}{reset_path}"))
            .bearer_auth("token")
            .json(&reset)
            .send()
            .await
            .expect("send HTTP position reset"),
        &base_url,
        "position-invalid-reset",
        ws_methods::TASK_BOARD_POSITION_RESET,
        with_id(reset, INVALID_ID),
    )
    .await;

    let after = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(after.items_change_seq, before.items_change_seq);
    assert_eq!(after.items[0].item_revision, before.items[0].item_revision);
    server.abort();
    let _ = server.await;
}

async fn assert_invalid_position_id_response(
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
    assert_eq!(http_body["error"]["code"], "KSRCLI059");
    let websocket = ws_rpc(base_url, request_id, method, params).await;
    let websocket_error = &websocket["error"];
    assert_eq!(websocket_error["code"], "KSRCLI059");
    assert_eq!(websocket_error["status_code"], 400);
    assert_eq!(websocket_error["data"], http_body);
}

fn with_id(mut params: serde_json::Value, id: &str) -> serde_json::Value {
    params["id"] = json!(id);
    params
}
