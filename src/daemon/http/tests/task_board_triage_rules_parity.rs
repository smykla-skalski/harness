use reqwest::StatusCode;
use serde_json::json;
use tempfile::tempdir;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::session::types::CONTROL_PLANE_ACTOR_ID;

use super::task_board_route_parity_support::{serve_http, ws_rpc};

fn empty_rule_set() -> serde_json::Value {
    json!({
        "schema_version": 1,
        "rules": [],
        "default_outcome": {"verdict": "undecided"}
    })
}

/// The server always echoes `priority_action` back explicitly (it is not
/// `skip_serializing_if`), even when the request omitted it and relied on
/// the `Keep` default -- this is the wire shape a read actually returns.
fn empty_rule_set_read_back() -> serde_json::Value {
    json!({
        "schema_version": 1,
        "rules": [],
        "default_outcome": {"verdict": "undecided", "priority_action": {"action": "keep"}}
    })
}

#[test]
fn task_board_triage_rules_draft_save_and_get_round_trip_binds_control_plane_actor() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_draft_save_and_get_round_trip());
    });
}

#[test]
fn task_board_triage_rules_activate_stale_cas_has_http_websocket_conflict_parity() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_activate_stale_cas_parity());
    });
}

#[test]
fn task_board_triage_rules_ws_draft_save_and_get_dispatch_through_real_state() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(assert_ws_draft_save_and_get_round_trip());
    });
}

async fn assert_draft_save_and_get_round_trip() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let save_payload = json!({
        "rules": empty_rule_set(),
        "expected_revision": null,
        "actor": "spoofed-client",
    });
    let save = client
        .put(format!("{base_url}{}", http_paths::TASK_BOARD_TRIAGE_RULES_DRAFT))
        .bearer_auth("token")
        .json(&save_payload)
        .send()
        .await
        .expect("send HTTP triage rules draft save");
    assert_eq!(save.status(), StatusCode::OK);
    let save_body = save
        .json::<serde_json::Value>()
        .await
        .expect("HTTP triage rules draft save body");
    assert!(save_body["persisted"].as_bool().expect("persisted flag"));
    assert_eq!(save_body["revision"], json!(1));

    let get = client
        .get(format!("{base_url}{}", http_paths::TASK_BOARD_TRIAGE_RULES_DRAFT))
        .bearer_auth("token")
        .send()
        .await
        .expect("send HTTP triage rules draft get");
    assert_eq!(get.status(), StatusCode::OK);
    let get_body = get
        .json::<serde_json::Value>()
        .await
        .expect("HTTP triage rules draft get body");
    // Proves control-plane actor binding end to end: the client-supplied
    // "spoofed-client" actor must never reach persistence.
    assert_eq!(get_body["draft"]["actor"], json!(CONTROL_PLANE_ACTOR_ID));
    assert_eq!(get_body["draft"]["revision"], json!(1));
    assert_eq!(get_body["draft"]["rules"], empty_rule_set_read_back());

    server.abort();
    let _ = server.await;
}

async fn assert_activate_stale_cas_parity() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let payload = json!({
        "rules": null,
        "expected_active_revision": 999,
        "actor": "attacker",
    });

    let http_response = client
        .post(format!("{base_url}{}", http_paths::TASK_BOARD_TRIAGE_RULES_ACTIVATE))
        .bearer_auth("token")
        .json(&payload)
        .send()
        .await
        .expect("send HTTP triage rules activate");
    assert_eq!(http_response.status(), StatusCode::CONFLICT);
    let http_body = http_response
        .json::<serde_json::Value>()
        .await
        .expect("HTTP error body");
    assert_eq!(http_body["error"]["code"], "WORKFLOW_CONCURRENT");

    let websocket = ws_rpc(
        &base_url,
        "activate-stale-ws",
        ws_methods::TASK_BOARD_TRIAGE_RULES_ACTIVATE,
        payload,
    )
    .await;
    let websocket_error = &websocket["error"];
    assert_eq!(websocket_error["code"], "WORKFLOW_CONCURRENT");
    assert_eq!(websocket_error["status_code"], 409);
    assert_eq!(websocket_error["data"], http_body);

    server.abort();
    let _ = server.await;
}

async fn assert_ws_draft_save_and_get_round_trip() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;

    let save = ws_rpc(
        &base_url,
        "triage-rules-draft-save-ws",
        ws_methods::TASK_BOARD_TRIAGE_RULES_DRAFT_SAVE,
        json!({
            "rules": empty_rule_set(),
            "expected_revision": null,
            "actor": "spoofed-client",
        }),
    )
    .await;
    assert!(save["result"]["persisted"].as_bool().expect("persisted flag"));
    assert_eq!(save["result"]["revision"], json!(1));

    let get = ws_rpc(
        &base_url,
        "triage-rules-draft-get-ws",
        ws_methods::TASK_BOARD_TRIAGE_RULES_DRAFT_GET,
        json!({}),
    )
    .await;
    // The get is dispatched through the same real daemon state the save
    // just wrote, not a static or contract-only stub.
    assert_eq!(get["result"]["draft"]["revision"], json!(1));
    assert_eq!(get["result"]["draft"]["actor"], json!(CONTROL_PLANE_ACTOR_ID));

    server.abort();
    let _ = server.await;
}
