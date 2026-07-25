//! Review write-action handlers - approve, merge, rerun-checks, label, auto,
//! request-review, and comment. They all return [`ReviewsActionResponse`] and
//! live in their own module so `reviews.rs` stays within the file-length cap.

use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::Json;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    ReviewsActionResponse, ReviewsApproveRequest, ReviewsAutoRequest, ReviewsCommentRequest,
    ReviewsLabelRequest, ReviewsMergeRequest, ReviewsRequestReviewRequest,
    ReviewsRerunChecksRequest, http_paths,
};
use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::openapi::DaemonErrorBody;
use super::response::{extract_request_id, timed_json};

/// Wire the review write-action endpoints onto the reviews router. These
/// handlers live in their own module so `reviews.rs` stays within the
/// file-length cap.
pub(super) fn merge_action_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router
        .routes(routes!(post_approve_reviews))
        .routes(routes!(post_merge_reviews))
        .routes(routes!(post_rerun_reviews_checks))
        .routes(routes!(post_label_reviews))
        .routes(routes!(post_auto_reviews))
        .routes(routes!(post_request_review))
        .routes(routes!(post_comment_reviews))
}

#[utoipa::path(
    post,
    path = "/v1/reviews/approve",
    tag = "reviews",
    description = "Approve the given review targets and report the outcome of applying each approval",
    request_body = ReviewsApproveRequest,
    responses(
        (status = 200, description = "Outcome of applying the approvals", body = ReviewsActionResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_approve_reviews(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/merge",
    tag = "reviews",
    description = "Merge the given pull requests and report the outcome for each target",
    request_body = ReviewsMergeRequest,
    responses(
        (status = 200, description = "Outcome of merging the targets", body = ReviewsActionResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_merge_reviews(
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
    timed_json("POST", http_paths::REVIEWS_MERGE, &request_id, start, result)
}

#[utoipa::path(
    post,
    path = "/v1/reviews/rerun-checks",
    tag = "reviews",
    description = "Re-run the failed status checks for the given targets and report the outcome",
    request_body = ReviewsRerunChecksRequest,
    responses(
        (status = 200, description = "Outcome of re-running the failed checks", body = ReviewsActionResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_rerun_reviews_checks(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/labels",
    tag = "reviews",
    description = "Add a label to the given review targets and report the outcome for each",
    request_body = ReviewsLabelRequest,
    responses(
        (status = 200, description = "Outcome of adding the label", body = ReviewsActionResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_label_reviews(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/auto",
    tag = "reviews",
    description = "Run the automatic approve-and-merge pass over the given targets and report the outcome",
    request_body = ReviewsAutoRequest,
    responses(
        (status = 200, description = "Outcome of the automatic approve-and-merge pass", body = ReviewsActionResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_auto_reviews(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/request-review",
    tag = "reviews",
    description = "Re-request review from the assigned reviewers on the given targets",
    request_body = ReviewsRequestReviewRequest,
    responses(
        (status = 200, description = "Outcome of re-requesting review", body = ReviewsActionResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_request_review(
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

#[utoipa::path(
    post,
    path = "/v1/reviews/comment",
    tag = "reviews",
    description = "Post a comment on the given review targets and report the outcome",
    request_body = ReviewsCommentRequest,
    responses(
        (status = 200, description = "Outcome of posting the comment", body = ReviewsActionResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_comment_reviews(
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
