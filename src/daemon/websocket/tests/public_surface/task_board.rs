use serde_json::{Value, json};

use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardStore, default_board_root};

use super::super::*;

mod catalog;

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
    seed_ready_board_item("board-ws-dispatch", "WS dispatch item");
    seed_ready_board_item("board-ws-dispatch-other", "WS dispatch other item");
    let dispatch_response =
        dispatch_ws_item(state, connection, "board-ws-dispatch", project_dir).await;
    let applied = first_applied(response_result(&dispatch_response));
    let session_id = required_string(applied, "session_id");
    let work_item_id = required_string(applied, "work_item_id");
    assert_eq!(applied["board_item_id"].as_str(), Some("board-ws-dispatch"));
    assert_eq!(applied["item"]["status"].as_str(), Some("in_progress"));
    assert_board_item_unlinked("board-ws-dispatch-other");

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
    assert_board_item_status("board-ws-dispatch", TaskBoardStatus::Done);
    assert_board_item_status("board-ws-dispatch-other", TaskBoardStatus::InProgress);
}

async fn run_websocket_task_board_run_once_flow(
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
    project_dir: &std::path::Path,
) {
    seed_ready_board_item("board-ws-run-once", "WS run once item");
    seed_ready_board_item("board-ws-run-once-other", "WS run once other item");
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
    assert_board_item_unlinked("board-ws-run-once-other");
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

#[test]
fn websocket_task_board_policy_pipeline_routes_round_trip() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));
            let workspace_response = dispatch(
                &request(
                    "req-policy-workspace",
                    ws_methods::TASK_BOARD_POLICY_CANVAS_WORKSPACE_GET,
                    json!({}),
                ),
                &state,
                &connection,
            )
            .await;
            let active_canvas_id = response_result(&workspace_response)["active_canvas_id"]
                .as_str()
                .expect("active canvas id")
                .to_string();

            let get_response = dispatch(
                &request(
                    "req-policy-get",
                    ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
                    json!({ "canvas_id": active_canvas_id.clone() }),
                ),
                &state,
                &connection,
            )
            .await;
            let pipeline = response_result(&get_response);
            assert_eq!(pipeline["schema_version"].as_u64(), Some(2));

            let save_response = dispatch(
                &request(
                    "req-policy-save",
                    ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT,
                    json!({
                        "canvas_id": active_canvas_id.clone(),
                        "document": pipeline.clone(),
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let save = response_result(&save_response);
            let saved_revision = save["document"]["revision"]
                .as_u64()
                .expect("saved revision");

            let simulation_response = dispatch(
                &request(
                    "req-policy-simulate",
                    ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE,
                    json!({
                        "canvas_id": active_canvas_id.clone(),
                        "document": save["document"].clone(),
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let simulation = response_result(&simulation_response);
            assert_eq!(simulation["revision"].as_u64(), Some(saved_revision));
            assert_eq!(simulation["succeeded"].as_bool(), Some(true));

            let promote_response = dispatch(
                &request(
                    "req-policy-promote",
                    ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE,
                    json!({
                        "canvas_id": active_canvas_id.clone(),
                        "revision": saved_revision,
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let promote = response_result(&promote_response);
            assert_eq!(promote["document"]["mode"].as_str(), Some("enforced"));

            let audit_response = dispatch(
                &request(
                    "req-policy-audit",
                    ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
                    json!({ "canvas_id": active_canvas_id }),
                ),
                &state,
                &connection,
            )
            .await;
            let audit = response_result(&audit_response);
            assert_eq!(audit["active_revision"].as_u64(), Some(saved_revision));
            assert_eq!(
                audit["latest_simulation"]["revision"].as_u64(),
                Some(saved_revision)
            );
        });
    });
}

#[test]
fn websocket_task_board_policy_optional_routes_accept_missing_params() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            let workspace_request: WsRequest = serde_json::from_value(json!({
                "id": "req-policy-workspace-defaults",
                "method": ws_methods::TASK_BOARD_POLICY_CANVAS_WORKSPACE_GET,
            }))
            .expect("workspace request with default params");
            let workspace_response = dispatch(&workspace_request, &state, &connection).await;
            assert!(
                workspace_response.error.is_none(),
                "unexpected workspace error: {:?}",
                workspace_response.error
            );
            let active_canvas_id =
                workspace_response.result.expect("workspace result")["active_canvas_id"]
                    .as_str()
                    .expect("active canvas id")
                    .to_string();
            assert!(
                active_canvas_id.starts_with("policy-canvas-"),
                "expected a seeded default canvas id, got {active_canvas_id:?}"
            );

            let pipeline_request: WsRequest = serde_json::from_value(json!({
                "id": "req-policy-get-defaults",
                "method": ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
            }))
            .expect("pipeline request with default params");
            let pipeline_response = dispatch(&pipeline_request, &state, &connection).await;
            assert!(
                pipeline_response.error.is_none(),
                "unexpected pipeline error: {:?}",
                pipeline_response.error
            );
            assert_eq!(
                pipeline_response.result.expect("pipeline result")["schema_version"].as_u64(),
                Some(2)
            );

            let audit_request: WsRequest = serde_json::from_value(json!({
                "id": "req-policy-audit-defaults",
                "method": ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
            }))
            .expect("audit request with default params");
            let audit_response = dispatch(&audit_request, &state, &connection).await;
            assert!(
                audit_response.error.is_none(),
                "unexpected audit error: {:?}",
                audit_response.error
            );
            assert_eq!(
                audit_response.result.expect("audit result")["active_revision"].as_u64(),
                Some(1)
            );
        });
    });
}

#[test]
fn websocket_task_board_policy_scenario_crud_roundtrips() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            let workspace_request: WsRequest = serde_json::from_value(json!({
                "id": "req-scenario-workspace",
                "method": ws_methods::TASK_BOARD_POLICY_CANVAS_WORKSPACE_GET,
            }))
            .expect("workspace request");
            let seeded = dispatch(&workspace_request, &state, &connection).await;
            let seeded_count = seeded.result.expect("workspace result")["scenarios"]
                .as_array()
                .expect("scenarios array")
                .len();
            assert!(seeded_count > 0, "workspace get seeds default scenarios");

            let create_request: WsRequest = serde_json::from_value(json!({
                "id": "req-scenario-create",
                "method": ws_methods::TASK_BOARD_POLICY_SCENARIO_CREATE,
                "params": { "name": "Risky merge", "input": { "action": "merge_pr" } },
            }))
            .expect("scenario create request");
            let created = dispatch(&create_request, &state, &connection).await;
            assert!(
                created.error.is_none(),
                "unexpected create error: {:?}",
                created.error
            );
            let created_scenarios = created.result.expect("create result")["scenarios"]
                .as_array()
                .expect("scenarios array")
                .clone();
            assert_eq!(created_scenarios.len(), seeded_count + 1);
            assert!(
                created_scenarios
                    .iter()
                    .any(|scenario| scenario["name"] == "Risky merge"),
                "the created scenario appears in the workspace"
            );

            let reset_request: WsRequest = serde_json::from_value(json!({
                "id": "req-scenario-reset",
                "method": ws_methods::TASK_BOARD_POLICY_SCENARIO_RESET,
            }))
            .expect("scenario reset request");
            let reset = dispatch(&reset_request, &state, &connection).await;
            assert!(
                reset.error.is_none(),
                "unexpected reset error: {:?}",
                reset.error
            );
            assert_eq!(
                reset.result.expect("reset result")["scenarios"]
                    .as_array()
                    .expect("scenarios array")
                    .len(),
                seeded_count
            );
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

fn assert_board_item_unlinked(id: &str) {
    let item = TaskBoardStore::new(default_board_root())
        .get(id)
        .expect("load board item");
    assert_eq!(item.status, TaskBoardStatus::Todo);
    assert!(item.work_item_id.is_none());
}

fn assert_board_item_status(id: &str, status: TaskBoardStatus) {
    let item = TaskBoardStore::new(default_board_root())
        .get(id)
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
