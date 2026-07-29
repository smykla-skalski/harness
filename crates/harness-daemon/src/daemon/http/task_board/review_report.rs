use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::http::openapi::DaemonErrorBody;
use crate::daemon::protocol::{TaskBoardGetItemRequest, http_paths};
use crate::task_board::TaskBoardAiReviewReportResponse;

use super::super::DaemonHttpState;
use super::super::response::timed_json;
use super::super::task_board_route_executor;
use super::items::authenticated_task_board_read;

#[utoipa::path(
    get,
    path = "/v1/task-board/items/{item_id}/review-report",
    tag = "task-board",
    description = "Return the current AI review state for one task-board item. An active execution takes precedence over older terminal reports",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    responses(
        (status = 200, description = "Not-started, running, completed, failed, or cancelled AI review state", body = TaskBoardAiReviewReportResponse),
        (status = 400, description = "Malformed or missing task-board item identifier", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_task_board_item_review_report(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, _) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM_REVIEW_REPORT,
        &request_id,
        start,
        task_board_route_executor::get_item_ai_review_report(
            &state,
            &TaskBoardGetItemRequest { id: item_id },
        )
        .await,
    )
}
