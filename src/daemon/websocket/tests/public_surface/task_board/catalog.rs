use serde_json::{Value, json};

use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardStatus, TaskBoardStore, default_board_root,
};

use super::*;

#[test]
fn websocket_task_board_catalog_routes_use_real_state() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            seed_catalog_board_item(
                "board-ws-catalog-a",
                "WS catalog alpha todo",
                "project-alpha",
                AgentMode::Planning,
                TaskBoardStatus::Todo,
            );
            seed_catalog_board_item(
                "board-ws-catalog-b",
                "WS catalog alpha running",
                "project-alpha",
                AgentMode::Planning,
                TaskBoardStatus::InProgress,
            );
            seed_catalog_board_item(
                "board-ws-catalog-c",
                "WS catalog beta todo",
                "project-beta",
                AgentMode::Evaluate,
                TaskBoardStatus::Todo,
            );

            let projects_response = dispatch(
                &request(
                    "req-catalog-projects",
                    ws_methods::TASK_BOARD_PROJECTS,
                    json!({}),
                ),
                &state,
                &connection,
            )
            .await;
            let projects = response_result(&projects_response);
            assert_project_summary(projects, "project-alpha", 2, 1);
            assert_project_summary(projects, "project-beta", 1, 1);

            let todo_projects_response = dispatch(
                &request(
                    "req-catalog-projects-todo",
                    ws_methods::TASK_BOARD_PROJECTS,
                    json!({ "status": "todo" }),
                ),
                &state,
                &connection,
            )
            .await;
            let todo_projects = response_result(&todo_projects_response);
            assert_project_summary(todo_projects, "project-alpha", 1, 1);
            assert_project_summary(todo_projects, "project-beta", 1, 1);

            let machines_response = dispatch(
                &request(
                    "req-catalog-machines",
                    ws_methods::TASK_BOARD_MACHINES,
                    json!({}),
                ),
                &state,
                &connection,
            )
            .await;
            let machines = response_result(&machines_response);
            assert_machine_summary(machines, "planning", 2, 1);
            assert_machine_summary(machines, "evaluate", 1, 1);

            let todo_machines_response = dispatch(
                &request(
                    "req-catalog-machines-todo",
                    ws_methods::TASK_BOARD_MACHINES,
                    json!({ "status": "todo" }),
                ),
                &state,
                &connection,
            )
            .await;
            let todo_machines = response_result(&todo_machines_response);
            assert_machine_summary(todo_machines, "planning", 1, 1);
            assert_machine_summary(todo_machines, "evaluate", 1, 1);
        });
    });
}

fn seed_catalog_board_item(
    id: &str,
    title: &str,
    project_id: &str,
    agent_mode: AgentMode,
    status: TaskBoardStatus,
) {
    let store = TaskBoardStore::new(default_board_root());
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a websocket catalog task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = status;
    item.project_id = Some(project_id.to_string());
    item.agent_mode = agent_mode;
    let title = item.title.clone();
    let body = item.body.clone();
    store.create(&title, &body, item).expect("create item");
}

fn assert_project_summary(value: &Value, project_id: &str, item_count: u64, ready_count: u64) {
    let summary = value
        .as_array()
        .and_then(|projects| {
            projects
                .iter()
                .find(|summary| summary["project_id"].as_str() == Some(project_id))
        })
        .unwrap_or_else(|| panic!("missing project summary {project_id}: {value}"));
    assert_eq!(summary["item_count"].as_u64(), Some(item_count));
    assert_eq!(summary["ready_count"].as_u64(), Some(ready_count));
}

fn assert_machine_summary(value: &Value, mode: &str, item_count: u64, ready_count: u64) {
    let summary = value
        .as_array()
        .and_then(|machines| {
            machines
                .iter()
                .find(|summary| summary["mode"].as_str() == Some(mode))
        })
        .unwrap_or_else(|| panic!("missing machine summary {mode}: {value}"));
    assert_eq!(summary["item_count"].as_u64(), Some(item_count));
    assert_eq!(summary["ready_count"].as_u64(), Some(ready_count));
}
