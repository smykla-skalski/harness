use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::http::openapi::DaemonErrorBody;
use crate::daemon::protocol::{TaskBoardGetItemRequest, http_paths};
use crate::task_board::TaskBoardWorkflowProgressResponse;
use harness_task_board_remote_viewer::project_task_board_workflow_progress;

use super::super::DaemonHttpState;
use super::super::response::timed_json;
use super::super::task_board_route_executor;
use super::items::authenticated_task_board_read;

#[utoipa::path(
    get,
    path = "/v1/task-board/items/{item_id}/workflow-progress",
    tag = "task-board",
    description = "Return durable dependency workflow progress and attempt evidence for one task-board item",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    responses(
        (status = 200, description = "Current durable workflow progress or an empty response when no workflow has started", body = TaskBoardWorkflowProgressResponse),
        (status = 400, description = "Malformed or missing task-board item identifier", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_task_board_item_workflow_progress(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result = task_board_route_executor::get_item_workflow_progress(
        &state,
        &TaskBoardGetItemRequest { id: item_id },
    )
    .await
    .map(|response| project_task_board_workflow_progress(response, viewer));
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM_WORKFLOW_PROGRESS,
        &request_id,
        start,
        result,
    )
}
