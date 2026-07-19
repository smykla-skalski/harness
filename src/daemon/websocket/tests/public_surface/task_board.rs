use serde_json::{Value, json};

use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::policy_graph::PolicyCanvasWorkspace;
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

use super::super::*;

mod catalog;
mod policy;

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
            let mut workspace = PolicyCanvasWorkspace::seeded();
            workspace.spawn_requires_live_policy = false;
            state
                .async_db
                .get()
                .expect("test async db")
                .replace_policy_workspace(&workspace)
                .await
                .expect("configure explicit websocket fallback");
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            run_websocket_task_board_item_scope_flow(&state, &connection, &project_dir).await;
            run_websocket_task_board_run_once_flow(&state, &connection, &project_dir).await;
        });
    });
}

async fn run_websocket_task_board_item_scope_flow(
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
    project_dir: &std::path::Path,
) {
    seed_ready_board_item(state, "board-ws-dispatch", "WS dispatch item").await;
    seed_ready_board_item(state, "board-ws-dispatch-other", "WS dispatch other item").await;
    let dispatch_response =
        dispatch_ws_item(state, connection, "board-ws-dispatch", project_dir).await;
    let applied = first_applied(response_result(&dispatch_response));
    let session_id = required_string(applied, "session_id");
    let work_item_id = required_string(applied, "work_item_id");
    assert_eq!(applied["board_item_id"].as_str(), Some("board-ws-dispatch"));
    assert_eq!(applied["item"]["status"].as_str(), Some("in_progress"));
    assert_board_item_unlinked(state, "board-ws-dispatch-other").await;

    let other_dispatch =
        dispatch_ws_item(state, connection, "board-ws-dispatch-other", project_dir).await;
    let other_applied = first_applied(response_result(&other_dispatch));
    let other_session_id = required_string(other_applied, "session_id");
    let other_work_item_id = required_string(other_applied, "work_item_id");
    join_leader(state, &session_id, project_dir).await;
    join_leader(state, &other_session_id, project_dir).await;

    mark_ws_task_done(state, connection, &session_id, &work_item_id).await;
    mark_ws_task_done(state, connection, &other_session_id, &other_work_item_id).await;
    let evaluation_response = dispatch(
        &request(
            "req-task-board-evaluate",
            ws_methods::TASK_BOARD_EVALUATE,
            json!({
                "id": "board-ws-dispatch",
                "status": "in_progress",
                "dry_run": false,
            }),
        ),
        state,
        connection,
    )
    .await;
    let evaluation_result = response_result(&evaluation_response);
    assert_eq!(evaluation_result["updated"].as_u64(), Some(1));
    assert_eq!(evaluation_result["completed"].as_u64(), Some(1));
    assert_eq!(
        evaluation_result["records"][0]["board_item_id"].as_str(),
        Some("board-ws-dispatch")
    );
    assert_board_item_status(state, "board-ws-dispatch", TaskBoardStatus::Done).await;
    assert_board_item_status(
        state,
        "board-ws-dispatch-other",
        TaskBoardStatus::InProgress,
    )
    .await;
}

async fn run_websocket_task_board_run_once_flow(
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
    project_dir: &std::path::Path,
) {
    seed_ready_board_item(state, "board-ws-run-once", "WS run once item").await;
    seed_ready_board_item(state, "board-ws-run-once-other", "WS run once other item").await;
    let run_once_response = dispatch(
        &request(
            "req-task-board-run-once",
            ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
            json!({
                "id": "board-ws-run-once",
                "status": "todo",
                "dry_run": false,
                "project_dir": project_dir,
            }),
        ),
        state,
        connection,
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
    assert_eq!(
        run_once_result["last_run"]["dispatch"]["applied"][0]["board_item_id"].as_str(),
        Some("board-ws-run-once")
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
    assert!(
        run_once_result["last_run"]["policy_trace_ids"]
            .as_array()
            .is_some_and(|trace_ids| !trace_ids.is_empty())
    );
    assert_board_item_unlinked(state, "board-ws-run-once-other").await;
}

async fn dispatch_ws_item(
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
    item_id: &str,
    project_dir: &std::path::Path,
) -> WsResponse {
    dispatch(
        &request(
            "req-task-board-dispatch",
            ws_methods::TASK_BOARD_DISPATCH,
            json!({
                "id": item_id,
                "status": "todo",
                "dry_run": false,
                "project_dir": project_dir,
            }),
        ),
        state,
        connection,
    )
    .await
}

async fn mark_ws_task_done(
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
    session_id: &str,
    work_item_id: &str,
) {
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
            state,
            connection,
        )
        .await,
    );
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
            fallback_role: Some(SessionRole::Worker),
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

async fn seed_ready_board_item(state: &DaemonHttpState, id: &str, title: &str) {
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a websocket integration task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Todo;
    item.workflow_kind = crate::task_board::TaskBoardWorkflowKind::Unknown;
    let item = submit_plan(&item, "Use task dispatch.").apply_to(&item);
    let item = approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item);
    state
        .async_db
        .get()
        .expect("async db")
        .create_task_board_item(item)
        .await
        .expect("create item");
}

fn first_applied(value: &Value) -> &Value {
    value["applied"]
        .as_array()
        .and_then(|applied| applied.first())
        .expect("first applied task")
}

async fn assert_board_item_unlinked(state: &DaemonHttpState, id: &str) {
    let item = state
        .async_db
        .get()
        .expect("async db")
        .task_board_item(id)
        .await
        .expect("load board item");
    assert_eq!(item.status, TaskBoardStatus::Todo);
    assert!(item.work_item_id.is_none());
}

async fn assert_board_item_status(state: &DaemonHttpState, id: &str, status: TaskBoardStatus) {
    let item = state
        .async_db
        .get()
        .expect("async db")
        .task_board_item(id)
        .await
        .expect("load board item");
    assert_eq!(item.status, status);
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
