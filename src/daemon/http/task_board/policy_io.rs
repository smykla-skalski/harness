use axum::Json;
use axum::Router;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;

use crate::daemon::protocol::{
    PolicyCanvasExportRequest, PolicyCanvasImportRequest, http_paths,
};

use super::super::response::timed_json;
use super::super::{DaemonHttpState, require_async_db, task_board_route_executor};
use super::authenticated_request;

pub(super) fn merge_policy_io_routes(router: Router<DaemonHttpState>) -> Router<DaemonHttpState> {
    router
        .route(
            http_paths::POLICY_CANVAS_EXPORT,
            post(post_policy_export),
        )
        .route(
            http_paths::POLICY_CANVAS_IMPORT,
            post(post_policy_import),
        )
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
