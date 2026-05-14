use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardListItemsRequest, TaskBoardUpdateItemRequest, WsRequest, WsResponse, ws_methods,
};
use crate::daemon::service;
use serde::de::DeserializeOwned;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

pub(crate) fn dispatch_task_board_method(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_CREATE => Some(dispatch_task_board_create(request)),
        ws_methods::TASK_BOARD_LIST => Some(dispatch_task_board_list(request)),
        ws_methods::TASK_BOARD_GET => Some(dispatch_task_board_get(request)),
        ws_methods::TASK_BOARD_UPDATE => Some(dispatch_task_board_update(request)),
        ws_methods::TASK_BOARD_DELETE => Some(dispatch_task_board_delete(request)),
        ws_methods::TASK_BOARD_SYNC => Some(dispatch_task_board_capability(request, "sync")),
        ws_methods::TASK_BOARD_DISPATCH => {
            Some(dispatch_task_board_capability(request, "dispatch"))
        }
        ws_methods::TASK_BOARD_AUDIT => Some(dispatch_task_board_capability(request, "audit")),
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

fn dispatch_task_board_capability(request: &WsRequest, operation: &str) -> WsResponse {
    dispatch_query_result(
        &request.id,
        Ok(service::task_board_not_configured(operation)),
    )
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> serde_json::Result<T> {
    serde_json::from_value(request.params.clone())
}

fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid task-board params")
}
