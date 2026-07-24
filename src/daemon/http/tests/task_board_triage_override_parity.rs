use reqwest::StatusCode;
use serde_json::json;
use tempfile::tempdir;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

use super::task_board_route_parity_support::{serve_http, ws_rpc};

#[test]
fn task_board_triage_override_set_and_clear_have_http_websocket_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_triage_override_set_and_clear_parity());
    });
}

#[test]
fn task_board_triage_override_stale_cas_has_http_websocket_conflict_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_stale_triage_override_cas_parity());
    });
}

#[test]
fn task_board_triage_override_clear_without_active_override_has_http_websocket_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_clear_without_active_override_parity());
    });
}

#[test]
fn task_board_triage_override_invalid_id_has_http_websocket_parity_without_writes() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_invalid_triage_override_id_parity_without_writes());
    });
}

async fn assert_triage_override_set_and_clear_parity() {
    let state = super::test_http_state_with_db();
    let db = state.async_db.get().expect("async db").clone();
    for id in ["override-http", "override-ws"] {
        let mut item = TaskBoardItem::new(
            id.into(),
            "Triage override".into(),
            "Verify override set/clear parity.".into(),
            "2026-07-23T00:00:00Z".into(),
        );
        item.status = TaskBoardStatus::Backlog;
        db.create_task_board_item(item).await.expect("create item");
    }
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    assert_set_parity(&client, &base_url).await;
    assert_clear_parity(&client, &base_url).await;

    server.abort();
    let _ = server.await;
}

async fn assert_set_parity(client: &reqwest::Client, base_url: &str) {
    let override_path =
        |id: &str| http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE.replace("{item_id}", id);

    let snapshot = get_position_snapshot(client, base_url, "override-http").await;
    let set_payload = json!({
        "verdict": "todo",
        "reason": "looks ready",
        "expected_item_revision": snapshot.0,
        "expected_items_change_seq": snapshot.1,
        "actor": "spoofed-client",
    });
    let http_set = client
        .put(format!("{base_url}{}", override_path("override-http")))
        .bearer_auth("token")
        .json(&set_payload)
        .send()
        .await
        .expect("send HTTP triage override set");
    assert_eq!(http_set.status(), StatusCode::OK);
    let http_set_body = http_set
        .json::<serde_json::Value>()
        .await
        .expect("HTTP triage override set body");
    assert_eq!(
        http_set_body["triage_override"]["actor"],
        crate::session::types::CONTROL_PLANE_ACTOR_ID
    );
    assert_eq!(http_set_body["snapshot"]["item"]["status"], "todo");

    let ws_snapshot = get_position_snapshot(client, base_url, "override-ws").await;
    let ws_set = ws_rpc(
        base_url,
        "override-ws-set",
        ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_SET,
        json!({
            "id": "override-ws",
            "verdict": "todo",
            "reason": "looks ready",
            "expected_item_revision": ws_snapshot.0,
            "expected_items_change_seq": ws_snapshot.1,
            "actor": "spoofed-client",
        }),
    )
    .await;
    assert_eq!(
        strip_item_id(ws_set["result"].clone()),
        strip_item_id(http_set_body.clone())
    );

    let http_current = get_json(
        client,
        base_url,
        &http_paths::TASK_BOARD_ITEM_TRIAGE.replace("{item_id}", "override-http"),
    )
    .await;
    assert_eq!(http_current["triage_override"]["verdict"], "todo");
    assert_eq!(http_current["effective"]["source"], "override");
}

async fn assert_clear_parity(client: &reqwest::Client, base_url: &str) {
    let override_clear_path =
        |id: &str| http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE_CLEAR.replace("{item_id}", id);

    let snapshot = get_position_snapshot(client, base_url, "override-http").await;
    let clear_payload = json!({
        "expected_item_revision": snapshot.0,
        "expected_items_change_seq": snapshot.1,
        "actor": "spoofed-client",
    });
    let http_clear = client
        .post(format!(
            "{base_url}{}",
            override_clear_path("override-http")
        ))
        .bearer_auth("token")
        .json(&clear_payload)
        .send()
        .await
        .expect("send HTTP triage override clear");
    assert_eq!(http_clear.status(), StatusCode::OK);
    let http_clear_body = http_clear
        .json::<serde_json::Value>()
        .await
        .expect("HTTP triage override clear body");
    assert!(http_clear_body["triage_override"].is_null());

    let ws_snapshot = get_position_snapshot(client, base_url, "override-ws").await;
    let ws_clear = ws_rpc(
        base_url,
        "override-ws-clear",
        ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_CLEAR,
        json!({
            "id": "override-ws",
            "expected_item_revision": ws_snapshot.0,
            "expected_items_change_seq": ws_snapshot.1,
            "actor": "spoofed-client",
        }),
    )
    .await;
    assert_eq!(
        strip_item_id(ws_clear["result"].clone()),
        strip_item_id(http_clear_body.clone())
    );
}

async fn assert_stale_triage_override_cas_parity() {
    let state = super::test_http_state_with_db();
    let mut item = TaskBoardItem::new(
        "override-stale".into(),
        "Triage override stale".into(),
        "Verify override CAS errors.".into(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    let db = state.async_db.get().expect("async db");
    db.create_task_board_item(item).await.expect("create item");
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let path = http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE.replace("{item_id}", "override-stale");
    let payload = json!({
        "verdict": "todo",
        "expected_item_revision": 999,
        "expected_items_change_seq": 999,
        "actor": "attacker",
    });

    let http_response = client
        .put(format!("{base_url}{path}"))
        .bearer_auth("token")
        .json(&payload)
        .send()
        .await
        .expect("send HTTP triage override set");
    assert_eq!(http_response.status(), StatusCode::CONFLICT);
    let http_body = http_response
        .json::<serde_json::Value>()
        .await
        .expect("HTTP error body");
    assert_eq!(http_body["error"]["code"], "WORKFLOW_CONCURRENT");

    let mut websocket_payload = payload.clone();
    websocket_payload["id"] = json!("override-stale");
    let websocket = ws_rpc(
        &base_url,
        "override-stale-ws",
        ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_SET,
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

async fn assert_clear_without_active_override_parity() {
    let state = super::test_http_state_with_db();
    let mut item = TaskBoardItem::new(
        "override-no-active".into(),
        "Triage override no active".into(),
        "Verify clear without an override errors.".into(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    let db = state.async_db.get().expect("async db");
    db.create_task_board_item(item).await.expect("create item");
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let path = http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE_CLEAR
        .replace("{item_id}", "override-no-active");
    let snapshot = get_position_snapshot(&client, &base_url, "override-no-active").await;
    let payload = json!({
        "expected_item_revision": snapshot.0,
        "expected_items_change_seq": snapshot.1,
        "actor": "attacker",
    });

    let http_response = client
        .post(format!("{base_url}{path}"))
        .bearer_auth("token")
        .json(&payload)
        .send()
        .await
        .expect("send HTTP triage override clear");
    assert_eq!(http_response.status(), StatusCode::BAD_REQUEST);
    let http_body = http_response
        .json::<serde_json::Value>()
        .await
        .expect("HTTP error body");

    let mut websocket_payload = payload.clone();
    websocket_payload["id"] = json!("override-no-active");
    let websocket = ws_rpc(
        &base_url,
        "override-no-active-ws",
        ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_CLEAR,
        websocket_payload,
    )
    .await;
    let websocket_error = &websocket["error"];
    assert_eq!(websocket_error["status_code"], 400);
    assert_eq!(websocket_error["data"], http_body);

    server.abort();
    let _ = server.await;
}

async fn assert_invalid_triage_override_id_parity_without_writes() {
    const INVALID_ID: &str = "unsafe..override";
    let state = super::test_http_state_with_db();
    let db = state.async_db.get().expect("async db").clone();
    db.create_task_board_item(TaskBoardItem::new(
        "override-safe".into(),
        "Triage override safe".into(),
        "Verify invalid ids make no mutation.".into(),
        "2026-07-23T00:00:00Z".into(),
    ))
    .await
    .expect("create item");
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    let path = http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE.replace("{item_id}", INVALID_ID);
    let clear_path =
        http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE_CLEAR.replace("{item_id}", INVALID_ID);
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let set = json!({
        "verdict": "todo",
        "expected_item_revision": 1,
        "expected_items_change_seq": before.items_change_seq,
        "actor": "attacker",
    });
    assert_invalid_override_id_response(
        client
            .put(format!("{base_url}{path}"))
            .bearer_auth("token")
            .json(&set)
            .send()
            .await
            .expect("send HTTP triage override set"),
        &base_url,
        "override-invalid-set",
        ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_SET,
        with_id(set, INVALID_ID),
    )
    .await;
    let clear = json!({
        "expected_item_revision": 1,
        "expected_items_change_seq": before.items_change_seq,
        "actor": "attacker",
    });
    assert_invalid_override_id_response(
        client
            .post(format!("{base_url}{clear_path}"))
            .bearer_auth("token")
            .json(&clear)
            .send()
            .await
            .expect("send HTTP triage override clear"),
        &base_url,
        "override-invalid-clear",
        ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_CLEAR,
        with_id(clear, INVALID_ID),
    )
    .await;

    let after = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(after.items_change_seq, before.items_change_seq);
    assert_eq!(after.items[0].item_revision, before.items[0].item_revision);
    server.abort();
    let _ = server.await;
}

async fn assert_invalid_override_id_response(
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
    assert_eq!(websocket_error["status_code"], 400);
    assert_eq!(websocket_error["data"], http_body);
}

fn with_id(mut params: serde_json::Value, id: &str) -> serde_json::Value {
    params["id"] = json!(id);
    params
}

/// The HTTP and WebSocket set/clear results legitimately differ in the
/// `item.id` field (`override-http` vs `override-ws`, seeded as two distinct
/// items so each transport proves a real, independent mutation) and in the
/// lane-ranking-dependent fields those two coexisting Todo-lane items
/// contend over (`lane_position`, `item_revision`, `items_change_seq`,
/// `shifted` -- clearing whichever of the two is cleared first shifts the
/// other's still-occupied Todo slot, clearing the second finds nothing left
/// to shift); every other field of the response must be byte-identical.
fn strip_item_id(mut value: serde_json::Value) -> serde_json::Value {
    if let Some(item) = value
        .get_mut("snapshot")
        .and_then(|snapshot| snapshot.get_mut("item"))
    {
        item["id"] = serde_json::Value::Null;
        item["lane_position"] = serde_json::Value::Null;
    }
    if let Some(snapshot) = value.get_mut("snapshot") {
        snapshot["item_revision"] = serde_json::Value::Null;
        snapshot["items_change_seq"] = serde_json::Value::Null;
    }
    if let Some(object) = value.as_object_mut() {
        object.remove("shifted");
    }
    value
}

async fn get_json(client: &reqwest::Client, base_url: &str, path: &str) -> serde_json::Value {
    client
        .get(format!("{base_url}{path}"))
        .bearer_auth("token")
        .send()
        .await
        .expect("send HTTP get")
        .json::<serde_json::Value>()
        .await
        .expect("HTTP get body")
}

async fn get_position_snapshot(
    client: &reqwest::Client,
    base_url: &str,
    item_id: &str,
) -> (i64, i64) {
    let path = http_paths::TASK_BOARD_ITEM_POSITION.replace("{item_id}", item_id);
    let body = get_json(client, base_url, &path).await;
    (
        body["item_revision"].as_i64().expect("item revision"),
        body["items_change_seq"].as_i64().expect("items change seq"),
    )
}
