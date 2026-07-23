use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardDispatchDeliverRequest, TaskBoardDispatchPickRequest, TaskBoardDispatchRequest,
    WsRequest, WsResponse,
};

use super::super::mutations::dispatch_query_result;
use super::{
    invalid_params, parse_control_plane_params, parse_params, parse_params_or_default,
    record_task_board_audit_result,
};

pub(super) async fn dispatch_task_board_dispatch(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardDispatchRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::dispatch(state, body).await;
    record_task_board_audit_result(
        state,
        "task_board.dispatch",
        "Dispatch task-board work",
        request
            .params
            .get("item_id")
            .and_then(serde_json::Value::as_str),
        serde_json::json!({ "request": &request.params }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

/// In step mode the reserve and the delivery are two calls behind one user
/// action, and only the delivery starts the worker. Auditing it keeps a failed
/// delivery from sitting unreconciled next to the reserve's success event,
/// which otherwise reads as a dispatch that simply worked. A dry run only
/// previews a held delivery, so it stays out of the trail.
pub(super) async fn dispatch_task_board_dispatch_deliver(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDispatchDeliverRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::deliver(state, &body).await;
    if !body.dry_run {
        record_task_board_audit_result(
            state,
            "task_board.dispatch_deliver",
            "Deliver task-board work",
            Some(body.item_id.as_str()),
            serde_json::json!({ "request": &request.params }),
            &result,
        )
        .await;
    }
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_dispatch_pick(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    if parse_params_or_default::<TaskBoardDispatchPickRequest>(request).is_err() {
        return invalid_params(request);
    }
    dispatch_query_result(&request.id, task_board_route_executor::pick(state).await)
}
