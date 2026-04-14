use std::time::Instant;

use axum::Json;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};

use crate::errors::{CliError, CliErrorKind};

pub(super) fn map_json<T: serde::Serialize>(result: Result<T, CliError>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(error) if error.code() == "SANDBOX001" => {
            let feature = match error.kind() {
                CliErrorKind::Common(common) => common.sandbox_feature().unwrap_or(""),
                _ => "",
            };
            (
                StatusCode::NOT_IMPLEMENTED,
                Json(serde_json::json!({
                    "error": "sandbox-disabled",
                    "feature": feature,
                })),
            )
                .into_response()
        }
        Err(error) if error.code() == "CODEX001" => {
            let endpoint = match error.kind() {
                CliErrorKind::Common(common) => common.codex_endpoint().unwrap_or(""),
                _ => "",
            };
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({
                    "error": "codex-unavailable",
                    "endpoint": endpoint,
                    "hint": "run: harness bridge start",
                })),
            )
                .into_response()
        }
        Err(error) if error.code() == "KSRCLI092" => (
            StatusCode::CONFLICT,
            Json(serde_json::json!({
                "error": {
                    "code": error.code(),
                    "message": error.message(),
                    "details": error.details(),
                }
            })),
        )
            .into_response(),
        Err(error) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "error": {
                    "code": error.code(),
                    "message": error.message(),
                    "details": error.details(),
                }
            })),
        )
            .into_response(),
    }
}

pub(super) fn timed_json<T: serde::Serialize>(
    method: &str,
    path: &str,
    request_id: &str,
    start: Instant,
    result: Result<T, CliError>,
) -> Response {
    let elapsed = start.elapsed().as_millis();
    let duration_ms = u64::try_from(elapsed).unwrap_or(u64::MAX);
    let status: u16 = match &result {
        Ok(_) => 200,
        Err(error) if error.code() == "SANDBOX001" => 501,
        Err(error) if error.code() == "CODEX001" => 503,
        Err(error) if error.code() == "KSRCLI092" => 409,
        Err(_) => 400,
    };
    log_request(method, path, status, duration_ms, request_id);
    map_json(result)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_request(method: &str, path: &str, status: u16, duration_ms: u64, request_id: &str) {
    tracing::event!(
        request_activity_log_level(),
        method,
        path,
        status,
        duration_ms,
        request_id,
        "daemon request"
    );
}

pub(super) const fn request_activity_log_level() -> tracing::Level {
    crate::DAEMON_ACTIVITY_LOG_LEVEL
}

pub(super) fn extract_request_id(headers: &HeaderMap) -> String {
    headers
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_string()
}
