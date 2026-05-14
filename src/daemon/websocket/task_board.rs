use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest,
    TaskBoardDispatchRequest, TaskBoardGetItemRequest, TaskBoardListItemsRequest,
    TaskBoardSyncRequest, TaskBoardUpdateItemRequest, WsRequest, WsResponse, ws_methods,
};
use crate::daemon::service;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use serde::de::DeserializeOwned;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

pub(crate) async fn dispatch_task_board_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_CREATE => Some(dispatch_task_board_create(request)),
        ws_methods::TASK_BOARD_LIST => Some(dispatch_task_board_list(request)),
        ws_methods::TASK_BOARD_GET => Some(dispatch_task_board_get(request)),
        ws_methods::TASK_BOARD_UPDATE => Some(dispatch_task_board_update(request)),
        ws_methods::TASK_BOARD_DELETE => Some(dispatch_task_board_delete(request)),
        ws_methods::TASK_BOARD_SYNC => Some(dispatch_task_board_sync(request)),
        ws_methods::TASK_BOARD_DISPATCH => Some(dispatch_task_board_dispatch(request, state).await),
        ws_methods::TASK_BOARD_AUDIT => Some(dispatch_task_board_audit(request)),
        _ => None,
    }
}

fn dispatch_task_board_create(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardCreateItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::create_task_board_item(&body))
}

fn dispatch_task_board_list(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardListItemsRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::list_task_board_items(&body))
}

fn dispatch_task_board_get(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGetItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::get_task_board_item(&body))
}

fn dispatch_task_board_update(request: &WsRequest) -> WsResponse {
    let Some(id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_params::<TaskBoardUpdateItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::update_task_board_item(id, &body))
}

fn dispatch_task_board_delete(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDeleteItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::delete_task_board_item(&body))
}

fn dispatch_task_board_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::sync_task_board(&body))
}

async fn dispatch_task_board_dispatch(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(mut body) = parse_params::<TaskBoardDispatchRequest>(request) else {
        return invalid_params(request);
    };
    body.actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
    let result = if let Some(async_db) = state.async_db.get() {
        let result = service::dispatch_task_board_async(&body, async_db.as_ref()).await;
        if result
            .as_ref()
            .is_ok_and(|response| !response.applied.is_empty())
        {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        result
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        let result = service::dispatch_task_board(&body, db_ref);
        if result
            .as_ref()
            .is_ok_and(|response| !response.applied.is_empty())
        {
            service::broadcast_sessions_updated(&state.sender, db_ref);
        }
        result
    };
    dispatch_query_result(&request.id, result)
}

fn dispatch_task_board_audit(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardAuditRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::audit_task_board(&body))
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> serde_json::Result<T> {
    serde_json::from_value(request.params.clone())
}

fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid task-board params")
}
