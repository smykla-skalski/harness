use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::{Json, Router};

use crate::daemon::protocol::{
    ReviewsPolicyHistoryRequest, ReviewsPolicyPreviewRequest, ReviewsPolicyRunStartRequest,
    ReviewsPolicyStatusRequest, http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

/// Resolve the request id and enforce auth in one step so each policy handler
/// shares the same gate without re-deriving it. Returns the timing start and
/// request id on success, or the early-return response on auth failure.
fn authenticated_policy_request(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<(Instant, String), Response> {
    let start = Instant::now();
    let request_id = extract_request_id(headers);
    if let Err(response) = require_auth(headers, state) {
        return Err(*response);
    }
    Ok((start, request_id))
}

pub(super) fn merge_policy_routes(router: Router<DaemonHttpState>) -> Router<DaemonHttpState> {
    use axum::routing::post;
    router
        .route(
            http_paths::REVIEWS_POLICY_PREVIEW,
            post(post_reviews_policy_preview),
        )
        .route(
            http_paths::REVIEWS_POLICY_START,
            post(post_reviews_policy_start),
        )
        .route(
            http_paths::REVIEWS_POLICY_STATUS,
            post(post_reviews_policy_status),
        )
        .route(
            http_paths::REVIEWS_POLICY_HISTORY,
            post(post_reviews_policy_history),
        )
}

async fn post_reviews_policy_preview(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPolicyPreviewRequest>,
) -> Response {
    let (start, request_id) = match authenticated_policy_request(&headers, &state) {
        Ok(context) => context,
        Err(response) => return response,
    };
    timed_json(
        "POST",
        http_paths::REVIEWS_POLICY_PREVIEW,
        &request_id,
        start,
        service::preview_reviews_policy(&request),
    )
}

async fn post_reviews_policy_start(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPolicyRunStartRequest>,
) -> Response {
    let (start, request_id) = match authenticated_policy_request(&headers, &state) {
        Ok(context) => context,
        Err(response) => return response,
    };
    let result = service::start_reviews_policy_run(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_POLICY_START,
        &request_id,
        start,
        result,
    )
}

async fn post_reviews_policy_status(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPolicyStatusRequest>,
) -> Response {
    let (start, request_id) = match authenticated_policy_request(&headers, &state) {
        Ok(context) => context,
        Err(response) => return response,
    };
    timed_json(
        "POST",
        http_paths::REVIEWS_POLICY_STATUS,
        &request_id,
        start,
        service::reviews_policy_status(&request),
    )
}

async fn post_reviews_policy_history(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPolicyHistoryRequest>,
) -> Response {
    let (start, request_id) = match authenticated_policy_request(&headers, &state) {
        Ok(context) => context,
        Err(response) => return response,
    };
    timed_json(
        "POST",
        http_paths::REVIEWS_POLICY_HISTORY,
        &request_id,
        start,
        service::reviews_policy_history(&request),
    )
}
