use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{delete, get, post};
use axum::{Json, Router};

use crate::daemon::protocol::{
    ReviewsActionPreviewRequest, ReviewsApproveRequest,
    ReviewsAutoRequest, ReviewsBodyRequest, ReviewsBodyUpdateRequest,
    ReviewsCommentRequest, ReviewsFilesBlobRequest,
    ReviewsFilesListRequest, ReviewsFilesPatchRequest,
    ReviewsFilesViewedRequest, ReviewsLabelRequest,
    ReviewsMergeRequest, ReviewsQueryRequest, ReviewsRefreshRequest,
    ReviewsRepositoryCatalogRequest, ReviewsRerunChecksRequest,
    ReviewsReviewThreadResolveRequest, ReviewsTimelineRequest, http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

macro_rules! authenticated_request {
    ($headers:expr, $state:expr) => {{
        let start = Instant::now();
        let request_id = extract_request_id(&$headers);
        if let Err(response) = require_auth(&$headers, &$state) {
            return *response;
        }
        (start, request_id)
    }};
}

pub(super) fn reviews_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::REVIEWS_REPOSITORIES,
            post(post_review_repositories),
        )
        .route(
            http_paths::REVIEWS_CAPABILITIES,
            get(get_review_capabilities),
        )
        .route(
            http_paths::REVIEWS_QUERY,
            post(post_query_reviews),
        )
        .route(
            http_paths::REVIEWS_ACTION_PREVIEW,
            post(post_review_action_preview),
        )
        .route(
            http_paths::REVIEWS_APPROVE,
            post(post_approve_reviews),
        )
        .route(
            http_paths::REVIEWS_MERGE,
            post(post_merge_reviews),
        )
        .route(
            http_paths::REVIEWS_RERUN_CHECKS,
            post(post_rerun_reviews_checks),
        )
        .route(
            http_paths::REVIEWS_LABELS,
            post(post_label_reviews),
        )
        .route(
            http_paths::REVIEWS_AUTO,
            post(post_auto_reviews),
        )
        .route(
            http_paths::REVIEWS_CACHE,
            delete(delete_reviews_cache),
        )
        .route(
            http_paths::REVIEWS_REFRESH,
            post(post_refresh_reviews),
        )
        .route(
            http_paths::REVIEWS_BODY,
            post(post_review_body),
        )
        .route(
            http_paths::REVIEWS_BODY_UPDATE,
            post(post_review_body_update),
        )
        .route(
            http_paths::REVIEWS_COMMENT,
            post(post_comment_reviews),
        )
        .route(
            http_paths::REVIEWS_FILES_LIST,
            post(post_review_files_list),
        )
        .route(
            http_paths::REVIEWS_FILES_PATCH,
            post(post_review_files_patch),
        )
        .route(
            http_paths::REVIEWS_FILES_VIEWED,
            post(post_review_files_viewed),
        )
        .route(
            http_paths::REVIEWS_FILES_BLOB,
            post(post_review_files_blob),
        )
        .route(
            http_paths::REVIEWS_FILES_LOCAL_CLONES,
            post(post_review_files_local_clones),
        )
        .route(
            http_paths::REVIEWS_FILES_LOCAL_CLONES_DELETE,
            post(post_review_files_local_clones_delete),
        )
        .route(
            http_paths::REVIEWS_TIMELINE,
            post(post_review_timeline),
        )
        .route(
            http_paths::REVIEWS_REVIEW_THREADS_RESOLVE,
            post(post_review_review_threads_resolve),
        )
}

async fn get_review_capabilities(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::query_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_QUERY,
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
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::REVIEWS_ACTION_PREVIEW,
        &request_id,
        start,
        service::preview_review_action(&request),
    )
}

async fn post_approve_reviews(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsApproveRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::auto_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_AUTO,
        &request_id,
        start,
        result,
    )
}

async fn delete_reviews_cache(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::fetch_review_body(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_BODY,
        &request_id,
        start,
        result,
    )
}

async fn post_review_body_update(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsBodyUpdateRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
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
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::comment_on_reviews(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_COMMENT,
        &request_id,
        start,
        result,
    )
}

async fn post_review_files_list(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsFilesListRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::list_review_files(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_LIST,
        &request_id,
        start,
        result,
    )
}

async fn post_review_files_patch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsFilesPatchRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::patch_review_files(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_PATCH,
        &request_id,
        start,
        result,
    )
}

async fn post_review_files_viewed(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsFilesViewedRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::mark_review_files_viewed(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_VIEWED,
        &request_id,
        start,
        result,
    )
}

async fn post_review_files_blob(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsFilesBlobRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::fetch_review_file_blob(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_BLOB,
        &request_id,
        start,
        result,
    )
}

async fn post_review_files_local_clones(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::list_review_local_clones().await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_LOCAL_CLONES,
        &request_id,
        start,
        result,
    )
}

#[derive(serde::Deserialize)]
struct DeleteLocalClonePayload {
    repo_key_segment: String,
}

#[derive(serde::Serialize)]
struct DeleteLocalCloneResponseBody {
    clones: Vec<crate::reviews::LocalCloneListEntry>,
}

async fn post_review_files_local_clones_delete(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(payload): Json<DeleteLocalClonePayload>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::delete_review_local_clone(&payload.repo_key_segment)
        .await
        .map(|clones| DeleteLocalCloneResponseBody { clones });
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_LOCAL_CLONES_DELETE,
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
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::fetch_review_timeline(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_TIMELINE,
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
    let (start, request_id) = authenticated_request!(headers, state);
    let result = service::set_review_thread_resolved(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_REVIEW_THREADS_RESOLVE,
        &request_id,
        start,
        result,
    )
}
