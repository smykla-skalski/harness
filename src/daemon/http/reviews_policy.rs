use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::Json;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    ReviewsPolicyHistoryRequest, ReviewsPolicyPreviewRequest, ReviewsPolicyRunStartRequest,
    ReviewsPolicyStatusRequest, http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::openapi::DaemonErrorBody;
use super::response::{extract_request_id, timed_json};

/// Resolve the request id and enforce auth in one step so each policy handler
/// shares the same gate without re-deriving it. Returns the timing start and
/// request id on success, or the early-return response on auth failure.
fn authenticated_policy_request(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<(Instant, String), Box<Response>> {
    let start = Instant::now();
    let request_id = extract_request_id(headers);
    require_auth(headers, state)?;
    Ok((start, request_id))
}

pub(super) fn merge_policy_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router
        .routes(routes!(post_reviews_policy_preview))
        .routes(routes!(post_reviews_policy_start))
        .routes(routes!(post_reviews_policy_status))
        .routes(routes!(post_reviews_policy_history))
}

#[utoipa::path(
    post,
    path = "/v1/reviews/policy/preview",
    tag = "reviews",
    description = "Preview the policy workflow steps that would run for a target, recording the preview to the audit database when configured",
    request_body = ReviewsPolicyPreviewRequest,
    responses(
        (status = 200, description = "Preview of the policy workflow steps for a target", body = crate::daemon::protocol::ReviewsPolicyPreviewResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_reviews_policy_preview(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPolicyPreviewRequest>,
) -> Response {
    let (start, request_id) = match authenticated_policy_request(&headers, &state) {
        Ok(context) => context,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::REVIEWS_POLICY_PREVIEW,
        &request_id,
        start,
        service::preview_reviews_policy_with_audit_db(&request, state.async_db.get().cloned())
            .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/policy/start",
    tag = "reviews",
    description = "Start a policy workflow run for a target, or resume an existing in-progress run",
    request_body = ReviewsPolicyRunStartRequest,
    responses(
        (status = 200, description = "The started (or resumed) policy run", body = crate::daemon::protocol::ReviewsPolicyRunResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_reviews_policy_start(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPolicyRunStartRequest>,
) -> Response {
    let (start, request_id) = match authenticated_policy_request(&headers, &state) {
        Ok(context) => context,
        Err(response) => return *response,
    };
    let result =
        service::start_reviews_policy_run_with_audit_db(&request, state.async_db.get().cloned())
            .await;
    timed_json(
        "POST",
        http_paths::REVIEWS_POLICY_START,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/policy/status",
    tag = "reviews",
    description = "Return the active and recent policy runs for a subject",
    request_body = ReviewsPolicyStatusRequest,
    responses(
        (status = 200, description = "Active and recent policy runs for a subject", body = crate::daemon::protocol::ReviewsPolicyStatusResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_reviews_policy_status(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPolicyStatusRequest>,
) -> Response {
    let (start, request_id) = match authenticated_policy_request(&headers, &state) {
        Ok(context) => context,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::REVIEWS_POLICY_STATUS,
        &request_id,
        start,
        service::reviews_policy_status_with_audit_db(&request, state.async_db.get().cloned()).await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/policy/history",
    tag = "reviews",
    description = "Return historical policy runs for a subject along with aggregate metrics",
    request_body = ReviewsPolicyHistoryRequest,
    responses(
        (status = 200, description = "Historical policy runs with aggregate metrics", body = crate::daemon::protocol::ReviewsPolicyHistoryResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_reviews_policy_history(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPolicyHistoryRequest>,
) -> Response {
    let (start, request_id) = match authenticated_policy_request(&headers, &state) {
        Ok(context) => context,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::REVIEWS_POLICY_HISTORY,
        &request_id,
        start,
        service::reviews_policy_history_with_audit_db(&request, state.async_db.get().cloned())
            .await,
    )
}
