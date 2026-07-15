use axum::Json;
use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;

use crate::daemon::protocol::{
    PolicyCanvasExportRequest, PolicyCanvasImportRequest, PolicyTransferDumpRequest,
    PolicyTransferImportRequest, http_paths,
};

use super::super::response::timed_json;
use super::super::{DaemonHttpState, require_async_db, task_board_route_executor};
use super::authenticated_request;

const POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES: usize = 64 * 1024 * 1024;

pub(super) fn merge_policy_io_routes(router: Router<DaemonHttpState>) -> Router<DaemonHttpState> {
    // Keep a finite last-resort ceiling for every buffered transfer request.
    // Remote requests are also bounded by the runtime-configured middleware.
    router
        .route(http_paths::POLICY_CANVAS_EXPORT, post(post_policy_export))
        .route(http_paths::POLICY_CANVAS_IMPORT, post(post_policy_import))
        .route(
            http_paths::POLICIES_DUMP,
            post(post_policy_dump)
                .layer(DefaultBodyLimit::max(POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES)),
        )
        .route(
            http_paths::POLICIES_IMPORT,
            post(post_policy_import_batch)
                .layer(DefaultBodyLimit::max(POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES)),
        )
}

pub(super) async fn post_policy_dump(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyTransferDumpRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let dump = match require_async_db(&state, "policy transfer dump") {
        Ok(db) => task_board_route_executor::dump_policy_transfer(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json("POST", http_paths::POLICIES_DUMP, &request_id, start, dump)
}

pub(super) async fn post_policy_export(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasExportRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let export = match require_async_db(&state, "policy export") {
        Ok(db) => task_board_route_executor::export_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVAS_EXPORT,
        &request_id,
        start,
        export,
    )
}

pub(super) async fn post_policy_import(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyCanvasImportRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let import = match require_async_db(&state, "policy import") {
        Ok(db) => task_board_route_executor::import_policy_canvas(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICY_CANVAS_IMPORT,
        &request_id,
        start,
        import,
    )
}

pub(super) async fn post_policy_import_batch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<PolicyTransferImportRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let import = match require_async_db(&state, "policy transfer import") {
        Ok(db) => task_board_route_executor::import_policy_transfer(db, &request).await,
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::POLICIES_IMPORT,
        &request_id,
        start,
        import,
    )
}
