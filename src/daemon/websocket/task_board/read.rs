use std::sync::{Arc, Mutex};

use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardGetItemRequest, TaskBoardListItemsRequest, WsRequest, WsResponse,
};
use crate::daemon::remote_task_board::{
    project_task_board_item, project_task_board_list, project_task_board_position_snapshot,
};

use super::super::connection::ConnectionState;
use super::super::dispatch::remote_viewer_projection_required;
use super::super::mutations::dispatch_query_result;
use super::{invalid_params, parse_params, parse_params_or_default};

pub(super) async fn dispatch_task_board_capabilities(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::capabilities(state).await,
    )
}

pub(super) async fn dispatch_task_board_list(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardListItemsRequest>(request) else {
        return invalid_params(request);
    };
    let viewer = remote_viewer_projection_required(connection);
    let result = task_board_route_executor::list_items(state, &body)
        .await
        .map(|response| project_task_board_list(response, viewer));
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_get(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGetItemRequest>(request) else {
        return invalid_params(request);
    };
    let viewer = remote_viewer_projection_required(connection);
    let result = task_board_route_executor::get_item(state, &body)
        .await
        .map(|item| project_task_board_item(item, viewer));
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_position_get(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGetItemRequest>(request) else {
        return invalid_params(request);
    };
    let viewer = remote_viewer_projection_required(connection);
    let result = task_board_route_executor::get_item_position_snapshot(state, &body.id)
        .await
        .map(|snapshot| project_task_board_position_snapshot(snapshot, viewer));
    dispatch_query_result(&request.id, result)
}
