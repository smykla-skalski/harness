use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{TaskBoardSyncRequest, WsRequest, WsResponse, ws_methods};

use super::{invalid_params, parse_params_or_default};
use crate::daemon::websocket::mutations::dispatch_query_result;

pub(super) async fn dispatch_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_SYNC => Some(dispatch_sync(request, state).await),
        ws_methods::TASK_BOARD_SYNC_CANCEL => Some(dispatch_query_result(
            &request.id,
            task_board_route_executor::cancel_sync(state),
        )),
        ws_methods::TASK_BOARD_SYNC_STATUS => Some(dispatch_query_result(
            &request.id,
            task_board_route_executor::sync_status(state),
        )),
        _ => None,
    }
}

async fn dispatch_sync(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::sync(state, &body).await,
    )
}
