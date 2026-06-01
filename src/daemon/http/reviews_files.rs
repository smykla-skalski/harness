use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;
use axum::{Json, Router};

use crate::daemon::protocol::{
    ReviewsFileCommentRequest, ReviewsFilesBlobRequest, ReviewsFilesListRequest,
    ReviewsFilesPatchRequest, ReviewsFilesPreviewRequest, ReviewsFilesViewedRequest, http_paths,
};
use crate::daemon::service;
use crate::reviews::LocalCloneListEntry;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

/// Wire the review-files endpoints onto the reviews router. These handlers live
/// in their own module so `reviews.rs` stays within the file-length cap.
pub(super) fn merge_files_routes(router: Router<DaemonHttpState>) -> Router<DaemonHttpState> {
    router
        .route(http_paths::REVIEWS_FILES_LIST, post(post_review_files_list))
        .route(
            http_paths::REVIEWS_FILES_PATCH,
            post(post_review_files_patch),
        )
        .route(
            http_paths::REVIEWS_FILES_PREVIEW,
            post(post_review_files_preview),
        )
        .route(
            http_paths::REVIEWS_FILES_VIEWED,
            post(post_review_files_viewed),
        )
        .route(http_paths::REVIEWS_FILES_BLOB, post(post_review_files_blob))
        .route(
            http_paths::REVIEWS_FILES_COMMENT,
            post(post_review_files_comment),
        )
        .route(
            http_paths::REVIEWS_FILES_LOCAL_CLONES,
            post(post_review_files_local_clones),
        )
        .route(
            http_paths::REVIEWS_FILES_LOCAL_CLONES_DELETE,
            post(post_review_files_local_clones_delete),
        )
}

async fn post_review_files_list(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsFilesListRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::patch_review_files(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_PATCH,
        &request_id,
        start,
        result,
    )
}

async fn post_review_files_preview(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsFilesPreviewRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::preview_review_files(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_PREVIEW,
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
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::fetch_review_file_blob(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_BLOB,
        &request_id,
        start,
        result,
    )
}

async fn post_review_files_comment(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<ReviewsFileCommentRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::add_review_file_comment(&request).await;
    timed_json(
        "POST",
        http_paths::REVIEWS_FILES_COMMENT,
        &request_id,
        start,
        result,
    )
}

async fn post_review_files_local_clones(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
    clones: Vec<LocalCloneListEntry>,
}

async fn post_review_files_local_clones_delete(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(payload): Json<DeleteLocalClonePayload>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
