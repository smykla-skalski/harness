//! HTTP handlers for task-board working copies (daemon-owned checkouts).
//!
//! Obtain-or-reuse a real checkout for an imported item's repository, list the
//! maintained checkouts, and delete one to reclaim disk. These live in their
//! own module so `task_board.rs` stays within the file-length cap.

use std::time::Instant;

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use serde::{Deserialize, Serialize};
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

use crate::daemon::protocol::http_paths;
use crate::daemon::service;
use crate::task_board::working_copy::WorkingCopyListEntry;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_json};

/// Request body for obtaining a working copy. `allow_clone` gates the
/// expensive path: delivery passes `false` (resolve-or-report-absent), the
/// explicit Settings/sheet action passes `true` (clone when missing).
#[derive(Deserialize, utoipa::ToSchema)]
pub(super) struct ObtainWorkingCopyPayload {
    repository: String,
    allow_clone: bool,
}

/// Response for obtain: `present` is false only when the copy is missing and
/// `allow_clone` was false, in which case `entry` is null.
#[derive(Serialize, utoipa::ToSchema)]
pub(super) struct ObtainWorkingCopyResponseBody {
    present: bool,
    entry: Option<WorkingCopyListEntry>,
}

#[derive(Deserialize, utoipa::ToSchema)]
pub(super) struct DeleteWorkingCopyPayload {
    repo_key_segment: String,
}

#[derive(Serialize, utoipa::ToSchema)]
pub(super) struct DeleteWorkingCopyResponseBody {
    working_copies: Vec<WorkingCopyListEntry>,
}

#[utoipa::path(
    post,
    path = "/v1/task-board/working-copies",
    tag = "task-board",
    responses(
        (status = 200, description = "Working-copy registry entries", body = Vec<crate::task_board::working_copy::WorkingCopyListEntry>),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_task_board_working_copies(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::list_task_board_working_copies().await;
    timed_json(
        "POST",
        http_paths::TASK_BOARD_WORKING_COPIES,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board/working-copies/obtain",
    tag = "task-board",
    request_body = ObtainWorkingCopyPayload,
    responses(
        (status = 200, description = "Obtained (or reused) working copy, if present", body = ObtainWorkingCopyResponseBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_task_board_working_copies_obtain(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(payload): Json<ObtainWorkingCopyPayload>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::obtain_task_board_working_copy(&payload.repository, payload.allow_clone)
        .await
        .map(|entry| ObtainWorkingCopyResponseBody {
            present: entry.is_some(),
            entry,
        });
    timed_json(
        "POST",
        http_paths::TASK_BOARD_WORKING_COPIES_OBTAIN,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board/working-copies/delete",
    tag = "task-board",
    request_body = DeleteWorkingCopyPayload,
    responses(
        (status = 200, description = "Working-copy registry after the deletion", body = DeleteWorkingCopyResponseBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_task_board_working_copies_delete(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(payload): Json<DeleteWorkingCopyPayload>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::delete_task_board_working_copy(&payload.repo_key_segment)
        .await
        .map(|working_copies| DeleteWorkingCopyResponseBody { working_copies });
    timed_json(
        "POST",
        http_paths::TASK_BOARD_WORKING_COPIES_DELETE,
        &request_id,
        start,
        result,
    )
}

/// Wire the working-copy endpoints onto the task-board OpenAPI router; the
/// paths come from each handler's `#[utoipa::path]` annotation.
pub(super) fn merge_working_copy_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router
        .routes(routes!(post_task_board_working_copies))
        .routes(routes!(post_task_board_working_copies_obtain))
        .routes(routes!(post_task_board_working_copies_delete))
}
