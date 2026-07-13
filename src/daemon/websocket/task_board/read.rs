use std::sync::{Arc, Mutex};

use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardGetItemRequest, TaskBoardListItemsRequest, WsRequest, WsResponse,
};
use crate::daemon::remote_task_board::{
    is_remote_viewer, project_task_board_item, project_task_board_list,
};

use super::super::connection::ConnectionState;
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
    let viewer = connection_is_remote_viewer(connection);
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
    let viewer = connection_is_remote_viewer(connection);
    let result = task_board_route_executor::get_item(state, &body)
        .await
        .map(|item| project_task_board_item(item, viewer));
    dispatch_query_result(&request.id, result)
}

fn connection_is_remote_viewer(connection: &Arc<Mutex<ConnectionState>>) -> bool {
    let Ok(connection) = connection.lock() else {
        return true;
    };
    is_remote_viewer(connection.remote_client())
}

#[cfg(test)]
mod tests {
    use std::panic::{AssertUnwindSafe, catch_unwind};

    use super::*;

    #[test]
    fn poisoned_connection_lock_keeps_viewer_projection_enabled() {
        let connection = Arc::new(Mutex::new(ConnectionState::new()));
        let panic = catch_unwind(AssertUnwindSafe(|| {
            let _guard = connection.lock().expect("connection lock");
            panic!("poison connection lock");
        }));

        assert!(panic.is_err());
        assert!(connection_is_remote_viewer(&connection));
    }
}
