use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{delete, get, post};
use axum::{Json, Router};

use crate::daemon::protocol::{
    ReviewsActionPreviewRequest, ReviewsApproveRequest, ReviewsAutoRequest, ReviewsAvatarRequest,
    ReviewsBodyRequest, ReviewsBodyUpdateRequest, ReviewsCommentRequest, ReviewsLabelRequest,
    ReviewsMergeRequest, ReviewsPullRequestResolveRequest, ReviewsQueryRequest,
    ReviewsRefreshRequest, ReviewsRepositoryCatalogRequest, ReviewsRequestReviewRequest,
    ReviewsRerunChecksRequest, ReviewsReviewThreadResolveRequest, ReviewsTimelineRequest,
    http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
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
    let router = router
        .route(http_paths::REVIEWS_APPROVE, post(post_approve_reviews))
        .route(http_paths::REVIEWS_MERGE, post(post_merge_reviews))
        .route(
            http_paths::REVIEWS_RERUN_CHECKS,
            post(post_rerun_reviews_checks),
        )
        .route(http_paths::REVIEWS_LABELS, post(post_label_reviews))
        .route(http_paths::REVIEWS_AUTO, post(post_auto_reviews))
        .route(
            http_paths::REVIEWS_REQUEST_REVIEW,
            post(post_request_review),
        )
        .route(http_paths::REVIEWS_CACHE, delete(delete_reviews_cache))
        .route(http_paths::REVIEWS_REFRESH, post(post_refresh_reviews))
        .route(http_paths::REVIEWS_BODY, post(post_review_body))
        .route(
            http_paths::REVIEWS_BODY_UPDATE,
            post(post_review_body_update),
        )
        .route(http_paths::REVIEWS_COMMENT, post(post_comment_reviews));
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

async fn get_review_capabilities(
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

async fn post_review_repositories(
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

async fn post_query_reviews(
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

async fn post_resolve_review_pull_requests(
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

async fn post_review_action_preview(
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

async fn post_approve_reviews(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsApproveRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::approve_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_APPROVE,
        &request_id,
        start,
        result,
    )
}

async fn post_merge_reviews(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsMergeRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::merge_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_MERGE,
        &request_id,
        start,
        result,
    )
}

async fn post_rerun_reviews_checks(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsRerunChecksRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::rerun_reviews_checks(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_RERUN_CHECKS,
        &request_id,
        start,
        result,
    )
}

async fn post_label_reviews(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsLabelRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::add_label_to_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_LABELS,
        &request_id,
        start,
        result,
    )
}

async fn post_auto_reviews(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsAutoRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::auto_reviews(&request).await;
    timed_json("POST", http_paths::REVIEWS_AUTO, &request_id, start, result)
}

async fn post_request_review(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsRequestReviewRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::request_review_for_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_REQUEST_REVIEW,
        &request_id,
        start,
        result,
    )
}

async fn delete_reviews_cache(
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

async fn post_refresh_reviews(
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

async fn post_review_body(
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

async fn post_review_body_update(
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

async fn post_comment_reviews(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsCommentRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::comment_on_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_COMMENT,
        &request_id,
        start,
        result,
    )
}

async fn post_review_timeline(
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

async fn post_review_avatar(
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

async fn post_review_review_threads_resolve(
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
