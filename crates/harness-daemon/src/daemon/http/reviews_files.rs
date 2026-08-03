use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use std::time::Instant;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    ReviewsFileCommentRequest, ReviewsFileCommentResponse, ReviewsFilesBlobRequest,
    ReviewsFilesBlobResponse, ReviewsFilesListRequest, ReviewsFilesListResponse,
    ReviewsFilesPatchRequest, ReviewsFilesPatchResponse, ReviewsFilesPreviewRequest,
    ReviewsFilesPreviewResponse, ReviewsFilesViewedRequest, ReviewsFilesViewedResponse, http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::openapi::DaemonErrorBody;
use super::response::{extract_request_id, timed_json};

/// Wire the review-files endpoints onto the reviews router.
pub(super) fn merge_files_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router.merge(review_file_content_routes())
}

fn review_file_content_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(post_review_files_list))
        .routes(routes!(post_review_files_patch))
        .routes(routes!(post_review_files_preview))
        .routes(routes!(post_review_files_viewed))
        .routes(routes!(post_review_files_blob))
        .routes(routes!(post_review_files_comment))
}

#[utoipa::path(
    post,
    path = "/v1/reviews/files/list",
    tag = "reviews",
    description = "List the files changed in a pull request",
    request_body = ReviewsFilesListRequest,
    responses(
        (status = 200, description = "Changed files for a pull request", body = ReviewsFilesListResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_files_list(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/files/patch",
    tag = "reviews",
    description = "Fetch the per-path patches for a pull request, detecting drift against the current upstream state",
    request_body = ReviewsFilesPatchRequest,
    responses(
        (status = 200, description = "Per-path patches with drift detection", body = ReviewsFilesPatchResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_files_patch(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/files/preview",
    tag = "reviews",
    description = "Fetch line-limited previews of the per-path patches for a pull request, detecting drift against upstream",
    request_body = ReviewsFilesPreviewRequest,
    responses(
        (status = 200, description = "Line-limited patch previews with drift detection", body = ReviewsFilesPreviewResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_files_preview(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/files/viewed",
    tag = "reviews",
    description = "Mark the given files as viewed or unviewed and report the outcome for each path",
    request_body = ReviewsFilesViewedRequest,
    responses(
        (status = 200, description = "Per-path viewed-state outcomes", body = ReviewsFilesViewedResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_files_viewed(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/files/blob",
    tag = "reviews",
    description = "Fetch a base64-encoded image blob for a file in a pull request, along with its metadata",
    request_body = ReviewsFilesBlobRequest,
    responses(
        (status = 200, description = "Base64-encoded image blob with metadata", body = ReviewsFilesBlobResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_files_blob(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/files/comment",
    tag = "reviews",
    description = "Post a line comment on a file or reply to an existing review thread",
    request_body = ReviewsFileCommentRequest,
    responses(
        (status = 200, description = "Result of posting the file comment or thread reply", body = ReviewsFileCommentResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_review_files_comment(
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
