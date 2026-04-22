use std::time::Instant;

use axum::Json;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use tracing::field::display;

use crate::errors::{CliError, CliErrorKind};
use crate::telemetry::record_daemon_http_metrics;

pub(crate) fn error_status_and_body(error: &CliError) -> (StatusCode, serde_json::Value) {
    if error.code() == "SANDBOX001" {
        let feature = match error.kind() {
            CliErrorKind::Common(common) => common.sandbox_feature().unwrap_or(""),
            _ => "",
        };
        return (
            StatusCode::NOT_IMPLEMENTED,
            serde_json::json!({
                "error": "sandbox-disabled",
                "feature": feature,
            }),
        );
    }
    if error.code() == "CODEX001" {
        let endpoint = match error.kind() {
            CliErrorKind::Common(common) => common.codex_endpoint().unwrap_or(""),
            _ => "",
        };
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            serde_json::json!({
                "error": "codex-unavailable",
                "endpoint": endpoint,
                "hint": "run: harness bridge start",
            }),
        );
    }
    if error.code() == "KSRCLI092" {
        return (
            StatusCode::CONFLICT,
            serde_json::json!({
                "error": {
                    "code": error.code(),
                    "message": error.message(),
                    "details": error.details(),
                }
            }),
        );
    }
    (
        StatusCode::BAD_REQUEST,
        serde_json::json!({
            "error": {
                "code": error.code(),
                "message": error.message(),
                "details": error.details(),
            }
        }),
    )
}

pub(super) fn map_json<T: serde::Serialize>(result: Result<T, CliError>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(error) => {
            let (status, body) = error_status_and_body(&error);
            (status, Json(body)).into_response()
        }
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
    record_daemon_http_metrics(method, path, status, duration_ms);
    let span = tracing::Span::current();
    span.record("http_status_code", display(status));
    span.record("duration_ms", display(duration_ms));
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
