use tempfile::tempdir;

use crate::daemon::protocol::http_paths;
use crate::task_board::policy_graph::PolicyCanvasWorkspace;

use super::task_board_support::{put_json, seed_ready_board_item, serve_http};
use super::*;

#[test]
fn task_board_http_dispatch_pick_accepts_empty_body() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_dispatch_pick_with_empty_body());
    });
}

async fn run_dispatch_pick_with_empty_body() {
    let state = test_http_state_with_db();
    allow_fallback_spawn_for_test(&state).await;
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();
    seed_ready_board_item(&state, "board-pick-low", "Low item").await;
    seed_ready_board_item(&state, "board-pick-high", "High item").await;
    put_json(
        &client,
        &base_url,
        "/v1/task-board/items/board-pick-high",
        serde_json::json!({ "priority": "critical" }),
    )
    .await;

    let response = client
        .post(format!(
            "{base_url}{}",
            http_paths::TASK_BOARD_DISPATCH_PICK
        ))
        .bearer_auth("token")
        .send()
        .await
        .expect("send bodyless dispatch-pick request");
    let status = response.status();
    let picked = response
        .json::<serde_json::Value>()
        .await
        .expect("decode dispatch-pick response");

    assert_eq!(
        status,
        StatusCode::OK,
        "bodyless dispatch pick returned {picked}"
    );
    assert_eq!(
        picked["selection"]["item"]["id"].as_str(),
        Some("board-pick-high")
    );
    assert_eq!(
        picked["selection"]["plan"]["board_item_id"].as_str(),
        Some("board-pick-high")
    );
    assert!(
        picked["selection"]["plan"]["rendered_prompt"]
            .as_str()
            .is_some_and(|prompt| prompt.contains("Board item: board-pick-high"))
    );

    server.abort();
    let _ = server.await;
}

async fn allow_fallback_spawn_for_test(state: &crate::daemon::http::DaemonHttpState) {
    let mut workspace = PolicyCanvasWorkspace::seeded();
    workspace.spawn_requires_live_policy = false;
    state
        .async_db
        .get()
        .expect("test async db")
        .replace_policy_workspace(&workspace)
        .await
        .expect("configure explicit test fallback");
}
