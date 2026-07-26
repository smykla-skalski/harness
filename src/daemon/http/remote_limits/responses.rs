//! The bodies a refused remote request gets back.
//!
//! One error code for every limit the daemon enforces, so a caller can tell a
//! refusal by policy from one by the route it was trying to reach without
//! matching on prose.

use axum::Json;
use axum::http::{HeaderValue, StatusCode, header::RETRY_AFTER};
use axum::response::{IntoResponse, Response};

const REMOTE_LIMIT_ERROR_CODE: &str = "REMOTE_LIMITS";

pub(super) fn unavailable_response() -> Response {
    limit_response(
        StatusCode::SERVICE_UNAVAILABLE,
        "remote request limits are unavailable",
    )
}

pub(super) fn overloaded_response(message: &str) -> Response {
    with_retry_after(limit_response(StatusCode::TOO_MANY_REQUESTS, message))
}

pub(super) fn with_retry_after(mut response: Response) -> Response {
    if response.status() != StatusCode::TOO_MANY_REQUESTS {
        return response;
    }
    if !response.headers().contains_key(RETRY_AFTER) {
        response
            .headers_mut()
            .insert(RETRY_AFTER, HeaderValue::from_static("1"));
    }
    response
}

pub(super) fn limit_response(status: StatusCode, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({
            "error": {
                "code": REMOTE_LIMIT_ERROR_CODE,
                "message": message,
            }
        })),
    )
        .into_response()
}
