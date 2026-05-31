use crate::daemon::http::task_board_route_executor;
use crate::daemon::http::{DaemonHttpState, require_async_db};
use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyPipelineAuditRequest,
    TaskBoardPolicyPipelineGetRequest, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest, WsRequest,
    WsResponse, ws_methods,
};

use super::super::mutations::dispatch_query_result;
use super::{invalid_params, parse_params, parse_params_or_default};

pub(super) async fn dispatch_task_board_policy_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_policy_canvas_method(request, state).await {
        return Some(response);
    }
    dispatch_policy_pipeline_method(request, state).await
}

async fn dispatch_policy_canvas_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_policy_canvas_read_method(request, state).await {
        return Some(response);
    }
    dispatch_policy_canvas_mutate_method(request, state).await
}

async fn dispatch_policy_canvas_read_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_CANVAS_WORKSPACE_GET => {
            Some(dispatch_task_board_policy_canvas_workspace_get(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_CREATE => {
            Some(dispatch_task_board_policy_canvas_create(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_DUPLICATE => {
            Some(dispatch_task_board_policy_canvas_duplicate(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_canvas_mutate_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_CANVAS_RENAME => {
            Some(dispatch_task_board_policy_canvas_rename(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_SET_ACTIVE => {
            Some(dispatch_task_board_policy_canvas_set_active(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_DELETE => {
            Some(dispatch_task_board_policy_canvas_delete(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_pipeline_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GET => {
            Some(dispatch_task_board_policy_pipeline_get(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT => {
            Some(dispatch_task_board_policy_pipeline_save_draft(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE => {
            Some(dispatch_task_board_policy_pipeline_simulate(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE => {
            Some(dispatch_task_board_policy_pipeline_promote(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT => {
            Some(dispatch_task_board_policy_pipeline_audit(request, state).await)
        }
        _ => None,
    }
}

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
    dispatch_query_result(
        &request.id,
        task_board_route_executor::create_policy_canvas(db, &body).await,
    )
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
    dispatch_query_result(
        &request.id,
        task_board_route_executor::duplicate_policy_canvas(db, &body).await,
    )
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
    dispatch_query_result(
        &request.id,
        task_board_route_executor::rename_policy_canvas(db, &body).await,
    )
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
    dispatch_query_result(
        &request.id,
        task_board_route_executor::set_active_policy_canvas(db, &body).await,
    )
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
    dispatch_query_result(
        &request.id,
        task_board_route_executor::delete_policy_canvas(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_pipeline_get(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyPipelineGetRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::policy_pipeline(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_pipeline_save_draft(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSaveDraftRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline save draft") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::save_policy_pipeline_draft(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_pipeline_simulate(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSimulateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline simulate") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::simulate_policy_pipeline(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_pipeline_promote(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelinePromoteRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline promote") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::promote_policy_pipeline(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_pipeline_audit(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyPipelineAuditRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline audit") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::audit_policy_pipeline(db, &body).await,
    )
}
