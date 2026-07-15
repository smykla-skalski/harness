use tempfile::tempdir;

use crate::daemon::protocol::http_paths;
use crate::task_board::{AgentMode, TaskBoardStatus};

use super::task_board_support::*;
use super::*;

#[test]
fn task_board_http_catalog_routes_use_real_state() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_http_catalog_flow());
    });
}

async fn run_task_board_http_catalog_flow() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    seed_catalog_board_item(
        &state,
        "board-http-catalog-a",
        "HTTP catalog alpha todo",
        "project-alpha",
        AgentMode::Planning,
        TaskBoardStatus::Todo,
    )
    .await;
    seed_catalog_board_item(
        &state,
        "board-http-catalog-b",
        "HTTP catalog alpha running",
        "project-alpha",
        AgentMode::Planning,
        TaskBoardStatus::InProgress,
    )
    .await;
    seed_catalog_board_item(
        &state,
        "board-http-catalog-c",
        "HTTP catalog beta todo",
        "project-beta",
        AgentMode::Evaluate,
        TaskBoardStatus::Todo,
    )
    .await;

    let projects = get_json(&client, &base_url, http_paths::TASK_BOARD_PROJECTS).await;
    assert_project_summary(&projects, "project-alpha", 2, 1);
    assert_project_summary(&projects, "project-beta", 1, 1);

    let todo_projects = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_PROJECTS),
    )
    .await;
    assert_project_summary(&todo_projects, "project-alpha", 1, 1);
    assert_project_summary(&todo_projects, "project-beta", 1, 1);

    let machines = get_json(&client, &base_url, http_paths::TASK_BOARD_MACHINES).await;
    assert_machine_summary(&machines, "planning", 2, 1);
    assert_machine_summary(&machines, "evaluate", 1, 1);

    let todo_machines = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_MACHINES),
    )
    .await;
    assert_machine_summary(&todo_machines, "planning", 1, 1);
    assert_machine_summary(&todo_machines, "evaluate", 1, 1);

    server.abort();
    let _ = server.await;
}
