use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;
use axum::{Json, Router};

use crate::daemon::protocol::{ImproverApplyRequest, http_paths};
use crate::daemon::service;
use crate::errors::CliError;
use crate::session::service::ImproverApplyOutcome;

use super::DaemonHttpState;
use super::auth::authorize_control_request;
use super::response::{extract_request_id, timed_json};

#[cfg(feature = "openapi")]
use super::openapi::DaemonErrorBody;

pub(super) fn improver_routes() -> Router<DaemonHttpState> {
    Router::new().route(
        http_paths::SESSION_IMPROVER_APPLY,
        post(post_improver_apply),
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/improver/apply",
    tag = "agents",
    params(("session_id" = String, Path, description = "Session identifier")),
    request_body = ImproverApplyRequest,
    responses(
        (status = 200, description = "Improver patch applied or previewed", body = ImproverApplyOutcome),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn post_improver_apply(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<ImproverApplyRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = improver_apply_response(&state, &session_id, &request).await;
    timed_json(
        "POST",
        http_paths::SESSION_IMPROVER_APPLY,
        &request_id,
        start,
        result,
    )
}

async fn improver_apply_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &ImproverApplyRequest,
) -> Result<ImproverApplyOutcome, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::improver_apply_async(session_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::improver_apply(session_id, request, db_guard.as_deref())
}
