use std::time::Instant;

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    ReviewsActionPreviewRequest, ReviewsActionPreviewResponse, ReviewsAvatarRequest,
    ReviewsAvatarResponse, ReviewsBodyRequest, ReviewsBodyResponse, ReviewsBodyUpdateRequest,
    ReviewsBodyUpdateResponse, ReviewsCacheClearResponse, ReviewsCapabilitiesResponse,
    ReviewsPullRequestResolveRequest, ReviewsPullRequestResolveResponse, ReviewsQueryRequest,
    ReviewsQueryResponse, ReviewsRefreshRequest, ReviewsRefreshResponse,
    ReviewsRepositoryCatalogRequest, ReviewsRepositoryCatalogResponse,
    ReviewsReviewThreadResolveRequest, ReviewsReviewThreadResolveResponse, ReviewsTimelineRequest,
    ReviewsTimelineResponse, http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::openapi::DaemonErrorBody;
use super::response::{extract_request_id, timed_json};

pub(super) fn reviews_routes() -> OpenApiRouter<DaemonHttpState> {
    let router = review_query_routes();
    // Policy preview/start/status/history handlers live in the sibling
    // `reviews_policy` module to keep this file within the line-length cap.
    let router = super::reviews_policy::merge_policy_routes(router);
    // Write-action handlers (approve/merge/rerun-checks/label/auto/
    // request-review/comment) live in the sibling `reviews_actions` module for
    // the same reason.
    let router = super::reviews_actions::merge_action_routes(router);
    let router = router.merge(review_content_routes());
    // Review-files preview/patch/blob/local-clone handlers live in the sibling
    // `reviews_files` module to keep this file within the line-length cap.
    let router = super::reviews_files::merge_files_routes(router);
    router.merge(review_thread_routes())
}

fn review_query_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(post_review_repositories))
        .routes(routes!(get_review_capabilities))
        .routes(routes!(post_query_reviews))
        .routes(routes!(post_resolve_review_pull_requests))
        .routes(routes!(post_review_action_preview))
}

fn review_content_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(delete_reviews_cache))
        .routes(routes!(post_refresh_reviews))
        .routes(routes!(post_review_body))
        .routes(routes!(post_review_body_update))
}

fn review_thread_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(post_review_avatar))
        .routes(routes!(post_review_timeline))
        .routes(routes!(post_review_review_threads_resolve))
}

#[utoipa::path(
    get,
    path = "/v1/reviews/capabilities",
    tag = "reviews",
    description = "Return the feature flags that gate review tooling capabilities for the authenticated caller",
    responses(
        (status = 200, description = "Feature flags for the review tooling", body = ReviewsCapabilitiesResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_review_capabilities(
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
        http_paths::REVIEWS_CAPABILITIES,
        &request_id,
        start,
        service::reviews_capabilities(),
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/repositories",
    tag = "reviews",
    description = "List the repositories the organization exposes for review, based on the request filters",
    request_body = ReviewsRepositoryCatalogRequest,
    responses(
        (status = 200, description = "Repositories the organization exposes for review", body = ReviewsRepositoryCatalogResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_repositories(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsRepositoryCatalogRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::catalog_review_repositories(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_REPOSITORIES,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/query",
    tag = "reviews",
    description = "Query reviews matching the given filters and return each with its summary",
    request_body = ReviewsQueryRequest,
    responses(
        (status = 200, description = "Matching reviews with their summary", body = ReviewsQueryResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_query_reviews(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsQueryRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::query_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_QUERY,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/pull-requests/resolve",
    tag = "reviews",
    description = "Resolve pull request references to review items, reporting any that could not be found",
    request_body = ReviewsPullRequestResolveRequest,
    responses(
        (status = 200, description = "Resolved pull requests plus any that were not found", body = ReviewsPullRequestResolveResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_resolve_review_pull_requests(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsPullRequestResolveRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::resolve_review_pull_requests(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_PULL_REQUEST_RESOLVE,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/action-preview",
    tag = "reviews",
    description = "Preview per-target eligibility for a review action before it is applied, recording the preview to the audit database when configured",
    request_body = ReviewsActionPreviewRequest,
    responses(
        (status = 200, description = "Per-target eligibility preview for an action", body = ReviewsActionPreviewResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_action_preview(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsActionPreviewRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        http_paths::REVIEWS_ACTION_PREVIEW,
        &request_id,
        start,
        service::preview_review_action_with_audit_db(&request, state.async_db.get().cloned()).await,
    )
}

#[utoipa::path(
    delete,
    path = "/v1/reviews/cache",
    tag = "reviews",
    description = "Clear all cached review data, including the timeline cache, and report the number of entries removed",
    responses(
        (status = 200, description = "Number of cache entries cleared", body = ReviewsCacheClearResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn delete_reviews_cache(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "DELETE",
        http_paths::REVIEWS_CACHE,
        &request_id,
        start,
        service::clear_reviews_caches_with_timeline(),
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/refresh",
    tag = "reviews",
    description = "Refresh the given review items from the upstream provider and return their updated state",
    request_body = ReviewsRefreshRequest,
    responses(
        (status = 200, description = "Refreshed review items", body = ReviewsRefreshResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_refresh_reviews(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsRefreshRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::refresh_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_REFRESH,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/body",
    tag = "reviews",
    description = "Fetch the current body text of a pull request",
    request_body = ReviewsBodyRequest,
    responses(
        (status = 200, description = "Pull request body text", body = ReviewsBodyResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_body(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsBodyRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::fetch_review_body(&request).await;
    timed_json("POST", http_paths::REVIEWS_BODY, &request_id, start, result)
}

#[utoipa::path(
    post,
    path = "/v1/reviews/body/update",
    tag = "reviews",
    description = "Update a pull request body, detecting drift if the body changed upstream since it was last read",
    request_body = ReviewsBodyUpdateRequest,
    responses(
        (status = 200, description = "Result of the body update, including drift detection", body = ReviewsBodyUpdateResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_body_update(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsBodyUpdateRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::update_review_body(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_BODY_UPDATE,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/timeline",
    tag = "reviews",
    description = "Fetch a page of a pull request's timeline events",
    request_body = ReviewsTimelineRequest,
    responses(
        (status = 200, description = "Paged pull request timeline", body = ReviewsTimelineResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_timeline(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsTimelineRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::fetch_review_timeline(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_TIMELINE,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/avatar",
    tag = "reviews",
    description = "Fetch and proxy a user's avatar image from GitHub, returned base64-encoded",
    request_body = ReviewsAvatarRequest,
    responses(
        (status = 200, description = "Base64-encoded avatar image proxied from GitHub", body = ReviewsAvatarResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_avatar(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsAvatarRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::fetch_review_avatar(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_AVATAR,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/reviews/review-threads/resolve",
    tag = "reviews",
    description = "Mark a review thread as resolved or unresolved and confirm the resulting state",
    request_body = ReviewsReviewThreadResolveRequest,
    responses(
        (status = 200, description = "Confirmed resolved state of the review thread", body = ReviewsReviewThreadResolveResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_review_threads_resolve(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsReviewThreadResolveRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::set_review_thread_resolved(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_REVIEW_THREADS_RESOLVE,
        &request_id,
        start,
        result,
    )
}
