//! HTTP handlers for worker progress on one dispatched task-board item.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::http::openapi::DaemonErrorBody;
use crate::daemon::protocol::{
    TaskBoardWorkItemProgressResponse, TaskBoardWorkItemReportRequest,
    TaskBoardWorkItemReportResponse, http_paths,
};

use super::super::DaemonHttpState;
use super::super::response::timed_json;
use super::super::task_board_route_executor;
use super::items::{authenticated_task_board_read, authorized_control_request_parts};

#[utoipa::path(
    get,
    path = "/v1/task-board/items/{item_id}/progress",
    tag = "task-board",
    description = "Return the durable worker progress and checkpoint log for one dispatched task-board item, or an empty response when the item has never been dispatched",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    responses(
        (status = 200, description = "Current worker progress, or an empty response before dispatch", body = TaskBoardWorkItemProgressResponse),
        (status = 400, description = "Invalid task-board request", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_task_board_item_progress(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, _viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result = task_board_route_executor::get_item_work_item_progress(&state, &item_id).await;
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM_PROGRESS,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board/items/{item_id}/progress/report",
    tag = "task-board",
    description = "Record one worker report against a dispatched task-board item. A report that arrives after the work settled, or out of order, is returned as an unapplied no-op with the current record rather than an error",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    request_body = TaskBoardWorkItemReportRequest,
    responses(
        (status = 200, description = "The record after the report, and whether the report moved it", body = TaskBoardWorkItemReportResponse),
        (status = 400, description = "Unknown item, an item that was never dispatched, or an invalid request", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_task_board_item_progress_report(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut payload): Json<TaskBoardWorkItemReportRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut payload)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result =
        task_board_route_executor::report_item_work_item_progress(&state, &item_id, &payload).await;
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ITEM_PROGRESS_REPORT,
        &request_id,
        start,
        result,
    )
}
