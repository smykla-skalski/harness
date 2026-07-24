use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardClearTriageOverrideRequest, TaskBoardSetTriageOverrideRequest, WsRequest, WsResponse,
};

use super::super::frames::error_response;
use super::super::mutations::dispatch_query_result;
use super::{invalid_params, parse_control_plane_params};

pub(super) async fn dispatch_triage_override_set(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(item_id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_control_plane_params::<TaskBoardSetTriageOverrideRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::set_item_triage_override(state, item_id, &body).await,
    )
}

pub(super) async fn dispatch_triage_override_clear(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(item_id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_control_plane_params::<TaskBoardClearTriageOverrideRequest>(request)
    else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::clear_item_triage_override(state, item_id, &body).await,
    )
}
