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

pub(super) fn improver_routes() -> Router<DaemonHttpState> {
    Router::new().route(http_paths::SESSION_IMPROVER_APPLY, post(post_improver_apply))
}

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
    let result = improver_apply_response(&session_id, &request);
    timed_json(
        "POST",
        http_paths::SESSION_IMPROVER_APPLY,
        &request_id,
        start,
        result,
    )
}

fn improver_apply_response(
    session_id: &str,
    request: &ImproverApplyRequest,
) -> Result<ImproverApplyOutcome, CliError> {
    service::improver_apply(session_id, request)
}
