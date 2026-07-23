use std::collections::BTreeSet;

use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::daemon::remote::RemoteRole;
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

use super::remote_viewer_support::{
    connect_remote_ws, get_http_json, register_remote_client, serve_http, ws_rpc,
};
use super::test_http_state_with_db;

const VIEWER_ID: &str = "viewer-task-board";
const OPERATOR_ID: &str = "operator-task-board";
const ITEM_ID: &str = "remote-sensitive-item";
const TRIAGE_ITEM_ID: &str = "remote-triage-item";

#[test]
fn remote_task_board_reads_minimize_viewer_payloads_for_http_and_websocket() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(run_remote_viewer_projection_flow());
    });
}

async fn run_remote_viewer_projection_flow() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.remote_domain = Some("daemon.example.com".to_string());
    register_remote_client(&state, VIEWER_ID, RemoteRole::Viewer);
    register_remote_client(&state, OPERATOR_ID, RemoteRole::Operator);
    seed_sensitive_item(&state).await;
    seed_triage_item(&state).await;

    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let viewer_list =
        get_http_json(&client, &base_url, http_paths::TASK_BOARD_ITEMS, VIEWER_ID).await;
    assert_viewer_projection(list_item_by_id(&viewer_list, ITEM_ID));
    assert!(viewer_list["items_change_seq"].is_i64());
    assert!(viewer_list["item_revisions"][ITEM_ID].is_i64());
    let viewer_item = get_http_json(
        &client,
        &base_url,
        &format!("{}/{}", http_paths::TASK_BOARD_ITEMS, ITEM_ID),
        VIEWER_ID,
    )
    .await;
    assert_viewer_projection(&viewer_item);
    let viewer_position = get_http_json(
        &client,
        &base_url,
        &http_paths::TASK_BOARD_ITEM_POSITION.replace("{item_id}", ITEM_ID),
        VIEWER_ID,
    )
    .await;
    assert_viewer_position_snapshot(&viewer_position);

    let viewer_triage_current = get_http_json(
        &client,
        &base_url,
        &http_paths::TASK_BOARD_ITEM_TRIAGE.replace("{item_id}", TRIAGE_ITEM_ID),
        VIEWER_ID,
    )
    .await;
    assert_viewer_triage_current(&viewer_triage_current);
    let viewer_triage_history = get_http_json(
        &client,
        &base_url,
        &http_paths::TASK_BOARD_ITEM_TRIAGE_HISTORY.replace("{item_id}", TRIAGE_ITEM_ID),
        VIEWER_ID,
    )
    .await;
    assert_viewer_triage_history(&viewer_triage_history);

    assert_viewer_position_mutations_are_denied(&client, &base_url).await;

    let operator_list = get_http_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ITEMS,
        OPERATOR_ID,
    )
    .await;
    assert_full_item(list_item_by_id(&operator_list, ITEM_ID));

    let operator_triage_current = get_http_json(
        &client,
        &base_url,
        &http_paths::TASK_BOARD_ITEM_TRIAGE.replace("{item_id}", TRIAGE_ITEM_ID),
        OPERATOR_ID,
    )
    .await;
    assert_full_triage_current(&operator_triage_current);

    let mut viewer_socket = connect_remote_ws(&base_url, VIEWER_ID).await;
    let viewer_ws_list = ws_rpc(
        &mut viewer_socket,
        "viewer-list",
        ws_methods::TASK_BOARD_LIST,
        json!({}),
    )
    .await;
    assert_viewer_projection(list_item_by_id(&viewer_ws_list["result"], ITEM_ID));
    let viewer_ws_item = ws_rpc(
        &mut viewer_socket,
        "viewer-get",
        ws_methods::TASK_BOARD_GET,
        json!({ "id": ITEM_ID }),
    )
    .await;
    assert_viewer_projection(&viewer_ws_item["result"]);
    let viewer_ws_position = ws_rpc(
        &mut viewer_socket,
        "viewer-position-get",
        ws_methods::TASK_BOARD_POSITION_GET,
        json!({ "id": ITEM_ID }),
    )
    .await;
    assert_viewer_position_snapshot(&viewer_ws_position["result"]);
    let viewer_ws_triage_current = ws_rpc(
        &mut viewer_socket,
        "viewer-triage-get",
        ws_methods::TASK_BOARD_TRIAGE_GET,
        json!({ "id": TRIAGE_ITEM_ID }),
    )
    .await;
    assert_viewer_triage_current(&viewer_ws_triage_current["result"]);
    let viewer_ws_triage_history = ws_rpc(
        &mut viewer_socket,
        "viewer-triage-history-get",
        ws_methods::TASK_BOARD_TRIAGE_HISTORY,
        json!({ "id": TRIAGE_ITEM_ID }),
    )
    .await;
    assert_viewer_triage_history(&viewer_ws_triage_history["result"]);
    let viewer_ws_set = ws_rpc(
        &mut viewer_socket,
        "viewer-position-set",
        ws_methods::TASK_BOARD_POSITION_SET,
        position_set_params(),
    )
    .await;
    assert_remote_write_denied(&viewer_ws_set);
    let viewer_ws_reset = ws_rpc(
        &mut viewer_socket,
        "viewer-position-reset",
        ws_methods::TASK_BOARD_POSITION_RESET,
        position_reset_params(),
    )
    .await;
    assert_remote_write_denied(&viewer_ws_reset);

    let mut operator_socket = connect_remote_ws(&base_url, OPERATOR_ID).await;
    let operator_ws_list = ws_rpc(
        &mut operator_socket,
        "operator-list",
        ws_methods::TASK_BOARD_LIST,
        json!({}),
    )
    .await;
    assert_full_item(list_item_by_id(&operator_ws_list["result"], ITEM_ID));
    let operator_ws_triage_current = ws_rpc(
        &mut operator_socket,
        "operator-triage-get",
        ws_methods::TASK_BOARD_TRIAGE_GET,
        json!({ "id": TRIAGE_ITEM_ID }),
    )
    .await;
    assert_full_triage_current(&operator_ws_triage_current["result"]);

    server.abort();
    let _ = server.await;
}

fn list_item_by_id<'a>(response: &'a Value, item_id: &str) -> &'a Value {
    response["items"]
        .as_array()
        .expect("task board items array")
        .iter()
        .find(|item| item["id"] == item_id)
        .unwrap_or_else(|| panic!("missing task board item '{item_id}'"))
}

async fn seed_sensitive_item(state: &crate::daemon::http::DaemonHttpState) {
    let item: TaskBoardItem = serde_json::from_value(json!({
        "schema_version": 1,
        "id": ITEM_ID,
        "title": "Deploy api_key=title-secret token=viewer-title-secret",
        "body": format!(
            "Authorization: Bearer abcdefghijklmnop {}",
            "private details ".repeat(20)
        ),
        "status": "todo",
        "priority": "high",
        "lane_position": 0,
        "lane_origin": { "kind": "manual", "actor": "sensitive-position-actor" },
        "lane_set_at": "2026-07-13T00:00:30Z",
        "tags": ["github_pat_abcdefghijklmnopqrstuvwxyz123456"],
        "project_id": "https://user:password@example.com/repo",
        "target_project_types": ["github"],
        "agent_mode": "headless",
        "external_refs": [{
            "provider": "github",
            "external_id": "owner/repo#123",
            "url": "https://github.com/owner/repo/issues/123"
        }],
        "planning": { "summary": "operator planning detail" },
        "workflow": {
            "status": "running",
            "branch": "c/private-branch",
            "worktree": "/Users/private/worktree",
            "last_error": "token=workflow-secret",
            "policy_trace_ids": ["trace-private"]
        },
        "session_id": "session-safe-id",
        "work_item_id": "work-safe-id",
        "usage": { "input_tokens": 100, "output_tokens": 50, "cost_usd": 1.25 },
        "created_at": "2026-07-13T00:00:00Z",
        "updated_at": "2026-07-13T00:01:00Z"
    }))
    .expect("sensitive task item");
    state
        .async_db
        .get()
        .expect("async db")
        .create_task_board_item(item)
        .await
        .expect("seed task item");
}

async fn seed_triage_item(state: &crate::daemon::http::DaemonHttpState) {
    let mut item = TaskBoardItem::new(
        TRIAGE_ITEM_ID.into(),
        "Triage item".into(),
        "Verify triage redaction.".into(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item.tags = vec!["triage/needs-info".to_string()];
    state
        .async_db
        .get()
        .expect("async db")
        .create_task_board_item_with_triage(item)
        .await
        .expect("seed triage item");
}

fn assert_viewer_triage_current(response: &Value) {
    let Some(current) = response["current"].as_object() else {
        panic!("expected a current triage decision, got {response}");
    };
    assert_eq!(current["item_id"], TRIAGE_ITEM_ID);
    assert!(current.get("reason_detail").is_some_and(Value::is_null));
    assert!(
        current
            .get("evidence_fingerprint")
            .is_some_and(Value::is_null)
    );
}

fn assert_viewer_triage_history(response: &Value) {
    let decisions = response["decisions"].as_array().expect("decisions array");
    assert!(!decisions.is_empty());
    for decision in decisions {
        assert!(decision.get("reason_detail").is_some_and(Value::is_null));
        assert!(
            decision
                .get("evidence_fingerprint")
                .is_some_and(Value::is_null)
        );
    }
}

fn assert_full_triage_current(response: &Value) {
    let current = response["current"]
        .as_object()
        .expect("expected a current triage decision");
    assert_eq!(current["reason_code"], "needs_info_label");
    assert_eq!(current["reason_detail"], "triage/needs-info");
    assert!(current["evidence_fingerprint"].as_str().is_some());
}

fn assert_viewer_projection(item: &Value) {
    let keys = item
        .as_object()
        .expect("viewer item object")
        .keys()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    assert_eq!(
        keys,
        BTreeSet::from([
            "agent_mode",
            "body",
            "created_at",
            "id",
            "lane_position",
            "priority",
            "project_id",
            "schema_version",
            "session_id",
            "status",
            "tags",
            "title",
            "updated_at",
            "work_item_id",
        ])
    );
    assert_eq!(item["id"], ITEM_ID);
    assert_eq!(item["session_id"], "session-safe-id");
    assert_eq!(item["work_item_id"], "work-safe-id");
    assert!(item["body"].as_str().expect("body").chars().count() <= 180);
    let serialized = serde_json::to_string(item).expect("serialize viewer item");
    for secret in [
        "title-secret",
        "viewer-title-secret",
        "abcdefghijklmnop",
        "github_pat_abcdefghijklmnopqrstuvwxyz123456",
        "user:password",
        "workflow-secret",
        "/Users/private/worktree",
        "operator planning detail",
    ] {
        assert!(!serialized.contains(secret), "viewer item exposed {secret}");
    }
    assert!(serialized.contains("[redacted]"));
}

fn assert_viewer_position_snapshot(snapshot: &Value) {
    assert_viewer_projection(&snapshot["item"]);
    assert!(snapshot["item_revision"].is_i64());
    assert!(snapshot["items_change_seq"].is_i64());
    let serialized = serde_json::to_string(snapshot).expect("serialize viewer position snapshot");
    assert!(!serialized.contains("sensitive-position-actor"));
    assert!(!serialized.contains("lane_origin"));
    assert!(!serialized.contains("lane_set_at"));
}

async fn assert_viewer_position_mutations_are_denied(client: &reqwest::Client, base_url: &str) {
    let position_path = http_paths::TASK_BOARD_ITEM_POSITION.replace("{item_id}", ITEM_ID);
    for (request, params) in [
        (
            client.put(format!("{base_url}{position_path}")),
            position_set_params(),
        ),
        (
            client.post(format!(
                "{base_url}{}",
                http_paths::TASK_BOARD_ITEM_POSITION_RESET.replace("{item_id}", ITEM_ID)
            )),
            position_reset_params(),
        ),
    ] {
        let response = request
            .header(
                crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER,
                VIEWER_ID,
            )
            .bearer_auth("remote-token-secret-viewer-task-board")
            .json(&params)
            .send()
            .await
            .expect("send viewer position mutation");
        let status = response.status();
        let body = response
            .json::<Value>()
            .await
            .expect("viewer mutation body");
        assert_eq!(status, reqwest::StatusCode::FORBIDDEN);
        assert_eq!(body["error"]["code"], "REMOTE_AUTH");
    }
}

fn assert_remote_write_denied(response: &Value) {
    assert_eq!(response["result"], Value::Null);
    assert_eq!(response["error"]["code"], "REMOTE_AUTH");
    assert_eq!(response["error"]["status_code"], 403);
}

fn position_set_params() -> Value {
    json!({
        "id": ITEM_ID,
        "status": "todo",
        "lane_position": 0,
        "expected_item_revision": 1,
        "expected_items_change_seq": 1,
        "actor": "spoofed-viewer",
    })
}

fn position_reset_params() -> Value {
    json!({
        "id": ITEM_ID,
        "expected_item_revision": 1,
        "expected_items_change_seq": 1,
        "actor": "spoofed-viewer",
    })
}

fn assert_full_item(item: &Value) {
    assert_eq!(item["workflow"]["worktree"], "/Users/private/worktree");
    assert_eq!(item["workflow"]["last_error"], "token=workflow-secret");
    assert_eq!(item["planning"]["summary"], "operator planning detail");
    assert_eq!(item["external_refs"][0]["external_id"], "owner/repo#123");
    assert_eq!(item["usage"]["cost_usd"].as_f64(), Some(1.25));
}
