use std::collections::BTreeSet;

use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::daemon::remote::RemoteRole;
use crate::task_board::TaskBoardItem;

use super::remote_viewer_support::{
    connect_remote_ws, get_http_json, register_remote_client, serve_http, ws_rpc,
};
use super::test_http_state_with_db;

const VIEWER_ID: &str = "viewer-task-board";
const OPERATOR_ID: &str = "operator-task-board";
const ITEM_ID: &str = "remote-sensitive-item";

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

    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let viewer_list =
        get_http_json(&client, &base_url, http_paths::TASK_BOARD_ITEMS, VIEWER_ID).await;
    assert_viewer_projection(&viewer_list["items"][0]);
    let viewer_item = get_http_json(
        &client,
        &base_url,
        &format!("{}/{}", http_paths::TASK_BOARD_ITEMS, ITEM_ID),
        VIEWER_ID,
    )
    .await;
    assert_viewer_projection(&viewer_item);

    let operator_list = get_http_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ITEMS,
        OPERATOR_ID,
    )
    .await;
    assert_full_item(&operator_list["items"][0]);

    let mut viewer_socket = connect_remote_ws(&base_url, VIEWER_ID).await;
    let viewer_ws_list = ws_rpc(
        &mut viewer_socket,
        "viewer-list",
        ws_methods::TASK_BOARD_LIST,
        json!({}),
    )
    .await;
    assert_viewer_projection(&viewer_ws_list["result"]["items"][0]);
    let viewer_ws_item = ws_rpc(
        &mut viewer_socket,
        "viewer-get",
        ws_methods::TASK_BOARD_GET,
        json!({ "id": ITEM_ID }),
    )
    .await;
    assert_viewer_projection(&viewer_ws_item["result"]);

    let mut operator_socket = connect_remote_ws(&base_url, OPERATOR_ID).await;
    let operator_ws_list = ws_rpc(
        &mut operator_socket,
        "operator-list",
        ws_methods::TASK_BOARD_LIST,
        json!({}),
    )
    .await;
    assert_full_item(&operator_ws_list["result"]["items"][0]);

    server.abort();
    let _ = server.await;
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

fn assert_full_item(item: &Value) {
    assert_eq!(item["workflow"]["worktree"], "/Users/private/worktree");
    assert_eq!(item["workflow"]["last_error"], "token=workflow-secret");
    assert_eq!(item["planning"]["summary"], "operator planning detail");
    assert_eq!(item["external_refs"][0]["external_id"], "owner/repo#123");
    assert_eq!(item["usage"]["cost_usd"].as_f64(), Some(1.25));
}
