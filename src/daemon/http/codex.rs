use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::daemon::protocol::{CodexApprovalDecisionRequest, CodexRunRequest, CodexSteerRequest};

use super::DaemonHttpState;
use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};

pub(super) fn codex_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            "/v1/sessions/{session_id}/codex-runs",
            get(get_codex_runs).post(post_codex_run),
        )
        .route("/v1/codex-runs/{run_id}", get(get_codex_run))
        .route("/v1/codex-runs/{run_id}/steer", post(post_codex_steer))
        .route(
            "/v1/codex-runs/{run_id}/interrupt",
            post(post_codex_interrupt),
        )
        .route(
            "/v1/codex-runs/{run_id}/approvals/{approval_id}",
            post(post_codex_approval),
        )
}

pub(super) async fn get_codex_runs(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        "/v1/sessions/{id}/codex-runs",
        &request_id,
        start,
        state.codex_controller.list_runs(&session_id),
    )
}

async fn post_codex_run(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<CodexRunRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/codex-runs",
        &request_id,
        start,
        state.codex_controller.start_run(&session_id, &request),
    )
}

pub(super) async fn get_codex_run(
    Path(run_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        "/v1/codex-runs/{id}",
        &request_id,
        start,
        state.codex_controller.run(&run_id),
    )
}

async fn post_codex_steer(
    Path(run_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<CodexSteerRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/codex-runs/{id}/steer",
        &request_id,
        start,
        state.codex_controller.steer(&run_id, &request),
    )
}

async fn post_codex_interrupt(
    Path(run_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/codex-runs/{id}/interrupt",
        &request_id,
        start,
        state.codex_controller.interrupt(&run_id),
    )
}

async fn post_codex_approval(
    Path((run_id, approval_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<CodexApprovalDecisionRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/codex-runs/{id}/approvals/{id}",
        &request_id,
        start,
        state
            .codex_controller
            .resolve_approval(&run_id, &approval_id, &request),
    )
}
