use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{delete, get, post};
use axum::{Json, Router};

use crate::daemon::protocol::{
    ReviewsActionPreviewRequest, ReviewsAvatarRequest, ReviewsBodyRequest, ReviewsBodyUpdateRequest,
    ReviewsPullRequestResolveRequest, ReviewsQueryRequest, ReviewsRefreshRequest,
    ReviewsRepositoryCatalogRequest, ReviewsReviewThreadResolveRequest, ReviewsTimelineRequest,
    http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
#[cfg(feature = "openapi")]
use super::openapi::DaemonErrorBody;
use super::response::{extract_request_id, timed_json};

pub(super) fn reviews_routes() -> Router<DaemonHttpState> {
    let router = Router::new()
        .route(
            http_paths::REVIEWS_REPOSITORIES,
            post(post_review_repositories),
        )
        .route(
            http_paths::REVIEWS_CAPABILITIES,
            get(get_review_capabilities),
        )
        .route(http_paths::REVIEWS_QUERY, post(post_query_reviews))
        .route(
            http_paths::REVIEWS_PULL_REQUEST_RESOLVE,
            post(post_resolve_review_pull_requests),
        )
        .route(
            http_paths::REVIEWS_ACTION_PREVIEW,
            post(post_review_action_preview),
        );
    // Policy preview/start/status/history handlers live in the sibling
    // `reviews_policy` module to keep this file within the line-length cap.
    let router = super::reviews_policy::merge_policy_routes(router);
    // Write-action handlers (approve/merge/rerun-checks/label/auto/
    // request-review/comment) live in the sibling `reviews_actions` module for
    // the same reason.
    let router = super::reviews_actions::merge_action_routes(router);
    let router = router
        .route(http_paths::REVIEWS_CACHE, delete(delete_reviews_cache))
        .route(http_paths::REVIEWS_REFRESH, post(post_refresh_reviews))
        .route(http_paths::REVIEWS_BODY, post(post_review_body))
        .route(
            http_paths::REVIEWS_BODY_UPDATE,
            post(post_review_body_update),
        );
    // Review-files preview/patch/blob/local-clone handlers live in the sibling
    // `reviews_files` module to keep this file within the line-length cap.
    let router = super::reviews_files::merge_files_routes(router);
    router
        .route(http_paths::REVIEWS_AVATAR, post(post_review_avatar))
        .route(http_paths::REVIEWS_TIMELINE, post(post_review_timeline))
        .route(
            http_paths::REVIEWS_REVIEW_THREADS_RESOLVE,
            post(post_review_review_threads_resolve),
        )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/reviews/capabilities",
    tag = "reviews",
    responses(
        (status = 200, description = "Feature flags for the review tooling", body = crate::daemon::protocol::ReviewsCapabilitiesResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/repositories",
    tag = "reviews",
    request_body = ReviewsRepositoryCatalogRequest,
    responses(
        (status = 200, description = "Repositories the organization exposes for review", body = crate::daemon::protocol::ReviewsRepositoryCatalogResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/query",
    tag = "reviews",
    request_body = ReviewsQueryRequest,
    responses(
        (status = 200, description = "Matching reviews with their summary", body = crate::daemon::protocol::ReviewsQueryResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/pull-requests/resolve",
    tag = "reviews",
    request_body = ReviewsPullRequestResolveRequest,
    responses(
        (status = 200, description = "Resolved pull requests plus any that were not found", body = crate::daemon::protocol::ReviewsPullRequestResolveResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/action-preview",
    tag = "reviews",
    request_body = ReviewsActionPreviewRequest,
    responses(
        (status = 200, description = "Per-target eligibility preview for an action", body = crate::daemon::protocol::ReviewsActionPreviewResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    delete,
    path = "/v1/reviews/cache",
    tag = "reviews",
    responses(
        (status = 200, description = "Number of cache entries cleared", body = crate::daemon::protocol::ReviewsCacheClearResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/refresh",
    tag = "reviews",
    request_body = ReviewsRefreshRequest,
    responses(
        (status = 200, description = "Refreshed review items", body = crate::daemon::protocol::ReviewsRefreshResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/body",
    tag = "reviews",
    request_body = ReviewsBodyRequest,
    responses(
        (status = 200, description = "Pull request body text", body = crate::daemon::protocol::ReviewsBodyResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/body/update",
    tag = "reviews",
    request_body = ReviewsBodyUpdateRequest,
    responses(
        (status = 200, description = "Result of the body update, including drift detection", body = crate::daemon::protocol::ReviewsBodyUpdateResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/timeline",
    tag = "reviews",
    request_body = ReviewsTimelineRequest,
    responses(
        (status = 200, description = "Paged pull request timeline", body = crate::daemon::protocol::ReviewsTimelineResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/avatar",
    tag = "reviews",
    request_body = ReviewsAvatarRequest,
    responses(
        (status = 200, description = "Base64-encoded avatar image proxied from GitHub", body = crate::daemon::protocol::ReviewsAvatarResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/reviews/review-threads/resolve",
    tag = "reviews",
    request_body = ReviewsReviewThreadResolveRequest,
    responses(
        (status = 200, description = "Confirmed resolved state of the review thread", body = crate::daemon::protocol::ReviewsReviewThreadResolveResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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
