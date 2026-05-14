use serde_json::{Value, json};

use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardStore, default_board_root};

use super::super::*;

#[test]
fn websocket_task_board_dispatch_evaluate_and_run_once_use_real_state() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let project_dir = sandbox.path().join("project");
            init_git_project(&project_dir);
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            seed_ready_board_item("board-ws-dispatch", "WS dispatch item");
            let dispatch_response = dispatch(
                &request(
                    "req-task-board-dispatch",
                    ws_methods::TASK_BOARD_DISPATCH,
                    json!({
                        "status": "todo",
                        "dry_run": false,
                        "project_dir": project_dir,
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let dispatch_result = response_result(&dispatch_response);
            let applied = first_applied(dispatch_result);
            let session_id = required_string(applied, "session_id");
            let work_item_id = required_string(applied, "work_item_id");
            assert_eq!(applied["item"]["status"].as_str(), Some("in_progress"));
            join_leader(&state, &session_id, &project_dir).await;

            assert_ok(
                dispatch(
                    &request(
                        "req-task-board-task-update",
                        ws_methods::TASK_UPDATE,
                        json!({
                            "session_id": session_id,
                            "task_id": work_item_id,
                            "actor": "spoofed-client",
                            "status": "done",
                            "note": "completed by test",
                        }),
                    ),
                    &state,
                    &connection,
                )
                .await,
            );
            let evaluation_response = dispatch(
                &request(
                    "req-task-board-evaluate",
                    ws_methods::TASK_BOARD_EVALUATE,
                    json!({
                        "status": "in_progress",
                        "dry_run": false,
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let evaluation_result = response_result(&evaluation_response);
            assert_eq!(evaluation_result["updated"].as_u64(), Some(1));
            assert_eq!(evaluation_result["completed"].as_u64(), Some(1));

            seed_ready_board_item("board-ws-run-once", "WS run once item");
            let run_once_response = dispatch(
                &request(
                    "req-task-board-run-once",
                    ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
                    json!({
                        "status": "todo",
                        "dry_run": false,
                        "project_dir": project_dir,
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let run_once_result = response_result(&run_once_response);
            assert_eq!(
                run_once_result["last_run"]["status"].as_str(),
                Some("completed")
            );
            assert_eq!(
                run_once_result["last_run"]["dispatch"]["applied"]
                    .as_array()
                    .map(Vec::len),
                Some(1)
            );
            assert!(
                run_once_result["last_run"]["evaluation"]["evaluated"]
                    .as_u64()
                    .is_some_and(|count| count >= 1)
            );
            assert!(evaluation_records_contain(
                run_once_result,
                "board-ws-run-once"
            ));
        });
    });
}

async fn join_leader(
    state: &crate::daemon::http::DaemonHttpState,
    session_id: &str,
    project_dir: &std::path::Path,
) {
    let async_db = state.async_db.get().expect("async db");
    join_session_direct_async(
        session_id,
        &SessionJoinRequest {
            runtime: "claude".into(),
            role: SessionRole::Leader,
            fallback_role: None,
            capabilities: Vec::new(),
            name: Some("leader".into()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            persona: None,
        },
        async_db.as_ref(),
    )
    .await
    .expect("join leader");
}

fn request(id: &str, method: &str, params: Value) -> WsRequest {
    WsRequest {
        id: id.to_string(),
        method: method.to_string(),
        params,
        trace_context: None,
    }
}

fn assert_ok(response: WsResponse) {
    assert!(
        response.error.is_none(),
        "unexpected error: {:?}",
        response.error
    );
}

fn response_result(response: &WsResponse) -> &Value {
    assert!(
        response.error.is_none(),
        "unexpected error: {:?}",
        response.error
    );
    response.result.as_ref().expect("websocket result")
}

fn seed_ready_board_item(id: &str, title: &str) {
    let store = TaskBoardStore::new(default_board_root());
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a websocket integration task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Todo;
    let item = submit_plan(&item, "Use task dispatch.").apply_to(&item);
    let item = approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item);
    let title = item.title.clone();
    let body = item.body.clone();
    store.create(&title, &body, item).expect("create item");
}

fn first_applied(value: &Value) -> &Value {
    value["applied"]
        .as_array()
        .and_then(|applied| applied.first())
        .expect("first applied task")
}

fn required_string(value: &Value, key: &str) -> String {
    value[key].as_str().expect("string field").to_string()
}

fn evaluation_records_contain(value: &Value, board_item_id: &str) -> bool {
    value["last_run"]["evaluation"]["records"]
        .as_array()
        .is_some_and(|records| {
            records
                .iter()
                .any(|record| record["board_item_id"].as_str() == Some(board_item_id))
        })
}
