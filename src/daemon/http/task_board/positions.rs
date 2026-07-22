use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::protocol::{
    TaskBoardResetItemPositionRequest, TaskBoardSetItemPositionRequest, http_paths,
};
use crate::daemon::remote_task_board::project_task_board_position_snapshot;

use super::super::DaemonHttpState;
use super::super::response::timed_json;
use super::super::task_board_route_executor;
use super::items::{authenticated_task_board_read, authorized_control_request_parts};

pub(super) async fn get_task_board_item_position_snapshot(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result = task_board_route_executor::get_item_position_snapshot(&state, &item_id)
        .await
        .map(|snapshot| project_task_board_position_snapshot(snapshot, viewer));
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM_POSITION,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn put_task_board_item_position(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardSetItemPositionRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ITEM_POSITION,
        &request_id,
        start,
        task_board_route_executor::set_item_position(&state, &item_id, &request).await,
    )
}

pub(super) async fn post_task_board_item_position_reset(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardResetItemPositionRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ITEM_POSITION_RESET,
        &request_id,
        start,
        task_board_route_executor::reset_item_position(&state, &item_id, &request).await,
    )
}
