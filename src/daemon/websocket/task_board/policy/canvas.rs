use crate::daemon::http::{DaemonHttpState, require_async_db, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasSetGlobalEnforcementRequest,
    TaskBoardPolicyPipelineGetRequest, WsRequest, WsResponse,
};
use crate::daemon::websocket::mutations::dispatch_query_result;

use super::super::{invalid_params, parse_params, parse_params_or_default};

pub(super) async fn dispatch_task_board_policy_canvas_workspace_get(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(_body) = parse_params_or_default::<TaskBoardPolicyPipelineGetRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas workspace") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::policy_canvas_workspace(db).await,
    )
}

pub(super) async fn dispatch_task_board_policy_canvas_create(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasCreateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas create") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::create_policy_canvas(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_create",
        "Create policy canvas",
        body.title.as_deref(),
        serde_json::json!({ "title": &body.title }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_duplicate(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasDuplicateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas duplicate") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::duplicate_policy_canvas(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_duplicate",
        "Duplicate policy canvas",
        Some(body.canvas_id.as_str()),
        serde_json::json!({
            "canvas_id": &body.canvas_id,
            "title": &body.title,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_rename(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasRenameRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas rename") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::rename_policy_canvas(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_rename",
        "Rename policy canvas",
        Some(body.canvas_id.as_str()),
        serde_json::json!({
            "canvas_id": &body.canvas_id,
            "title": &body.title,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_set_active(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasSetActiveRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas set active") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::set_active_policy_canvas(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_set_active",
        "Set active policy canvas",
        Some(body.canvas_id.as_str()),
        serde_json::json!({ "canvas_id": &body.canvas_id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_delete(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasDeleteRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas delete") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::delete_policy_canvas(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_delete",
        "Delete policy canvas",
        Some(body.canvas_id.as_str()),
        serde_json::json!({ "canvas_id": &body.canvas_id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_set_global_enforcement(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasSetGlobalEnforcementRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas global enforcement") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::set_policy_canvas_global_enforcement(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_set_global_enforcement",
        "Set global policy enforcement",
        None,
        serde_json::json!({ "enabled": body.enabled }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}
