use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Json;
use axum::body::Body;
use axum::extract::State;
use axum::extract::ws::WebSocketUpgrade;
use axum::http::{HeaderValue, Request, StatusCode, header::CONTENT_LENGTH, header::RETRY_AFTER};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use http_body_util::{BodyExt as _, Limited};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, TryAcquireError};
use tokio::time::timeout;

use super::auth::RemoteHttpLimitAudit;
use super::auth_audit::RemoteHttpAuditMarker;
use super::task_board::{POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES, policy_transfer_http_body_limit};
use super::{DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::remote_request_audit::{
    RemoteUnauthenticatedAuditAdmission, RemoteUnauthenticatedAuditLimiter,
};
use crate::daemon::remote_tls::{
    DEFAULT_MAX_CONCURRENT_TLS_HANDSHAKES, DEFAULT_TLS_HANDSHAKE_TIMEOUT,
};
use crate::daemon::task_board_remote_transport::routes::{
    DEFAULT_EXECUTION_HTTP_BODY_LIMIT_BYTES, MAX_EXECUTION_HTTP_BODY_LIMIT_BYTES,
    execution_http_body_limit,
};
use crate::errors::{CliError, CliErrorKind};

const REMOTE_LIMIT_ERROR_CODE: &str = "REMOTE_LIMITS";
pub(crate) const DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES: usize =
    DEFAULT_EXECUTION_HTTP_BODY_LIMIT_BYTES;
pub(crate) const MAX_REMOTE_HTTP_BODY_LIMIT_BYTES: usize =
    if MAX_EXECUTION_HTTP_BODY_LIMIT_BYTES > POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES {
        MAX_EXECUTION_HTTP_BODY_LIMIT_BYTES
    } else {
        POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES
    };

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RemoteRequestLimitConfig {
    pub max_http_body_bytes: usize,
    pub max_http_header_bytes: usize,
    pub max_http_uri_bytes: usize,
    pub max_http_concurrency: usize,
    pub max_unauthenticated_audit_attempts: u32,
    pub max_unauthenticated_audit_attempts_per_remote_addr: u32,
    pub unauthenticated_audit_window: Duration,
    pub request_timeout: Duration,
    pub max_concurrent_tls_handshakes: usize,
    pub tls_handshake_timeout: Duration,
    pub max_websocket_message_bytes: usize,
    pub max_websocket_frame_bytes: usize,
    pub max_websocket_connections: usize,
    pub max_websocket_in_flight_requests: usize,
}

impl Default for RemoteRequestLimitConfig {
    fn default() -> Self {
        Self {
            max_http_body_bytes: MAX_REMOTE_HTTP_BODY_LIMIT_BYTES,
            max_http_header_bytes: 64 * 1024,
            max_http_uri_bytes: 8 * 1024,
            max_http_concurrency: 32,
            max_unauthenticated_audit_attempts: 60,
            max_unauthenticated_audit_attempts_per_remote_addr: 5,
            unauthenticated_audit_window: Duration::from_secs(60),
            request_timeout: Duration::from_mins(3),
            max_concurrent_tls_handshakes: DEFAULT_MAX_CONCURRENT_TLS_HANDSHAKES,
            tls_handshake_timeout: DEFAULT_TLS_HANDSHAKE_TIMEOUT,
            max_websocket_message_bytes: 4 * 1024 * 1024,
            max_websocket_frame_bytes: 4 * 1024 * 1024,
            max_websocket_connections: 64,
            max_websocket_in_flight_requests: 16,
        }
    }
}

impl RemoteRequestLimitConfig {
    /// Validate every remote resource boundary before opening a listener.
    ///
    /// # Errors
    /// Returns [`CliError`] when a boundary is disabled or internally inconsistent.
    pub fn validate(self) -> Result<(), CliError> {
        let values = [
            ("HTTP body bytes", self.max_http_body_bytes),
            ("HTTP header bytes", self.max_http_header_bytes),
            ("HTTP URI bytes", self.max_http_uri_bytes),
            ("HTTP concurrency", self.max_http_concurrency),
            (
                "concurrent TLS handshakes",
                self.max_concurrent_tls_handshakes,
            ),
            ("WebSocket message bytes", self.max_websocket_message_bytes),
            ("WebSocket frame bytes", self.max_websocket_frame_bytes),
            ("WebSocket connections", self.max_websocket_connections),
            (
                "WebSocket in-flight requests",
                self.max_websocket_in_flight_requests,
            ),
        ];
        if let Some((name, _)) = values.into_iter().find(|(_, value)| *value == 0) {
            return Err(CliErrorKind::workflow_parse(format!(
                "remote request limits require non-zero {name}"
            ))
            .into());
        }
        if self.request_timeout.is_zero() {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require a non-zero timeout",
            )
            .into());
        }
        if self.max_unauthenticated_audit_attempts == 0
            || self.max_unauthenticated_audit_attempts_per_remote_addr == 0
        {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require non-zero unauthenticated audit attempt limits",
            )
            .into());
        }
        if self.unauthenticated_audit_window.is_zero() {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require a non-zero unauthenticated audit window",
            )
            .into());
        }
        if self.tls_handshake_timeout.is_zero() {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require a non-zero TLS handshake timeout",
            )
            .into());
        }
        if self.max_websocket_frame_bytes > self.max_websocket_message_bytes {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require the WebSocket frame limit to fit within the message limit",
            )
            .into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct RemoteRequestLimits {
    config: RemoteRequestLimitConfig,
    http_permits: Arc<Semaphore>,
    websocket_permits: Arc<Semaphore>,
    unauthenticated_audit_limiter: Arc<Mutex<RemoteUnauthenticatedAuditLimiter>>,
}

impl RemoteRequestLimits {
    /// Build runtime limit state from validated configuration.
    ///
    /// # Errors
    /// Returns [`CliError`] when the configuration disables a required limit.
    pub fn new(config: RemoteRequestLimitConfig) -> Result<Self, CliError> {
        config.validate()?;
        Ok(Self {
            config,
            http_permits: Arc::new(Semaphore::new(config.max_http_concurrency)),
            websocket_permits: Arc::new(Semaphore::new(config.max_websocket_connections)),
            unauthenticated_audit_limiter: Arc::new(Mutex::new(
                RemoteUnauthenticatedAuditLimiter::new(
                    config.max_unauthenticated_audit_attempts,
                    config.max_unauthenticated_audit_attempts_per_remote_addr,
                    config.unauthenticated_audit_window,
                ),
            )),
        })
    }

    #[must_use]
    pub const fn config(&self) -> RemoteRequestLimitConfig {
        self.config
    }

    fn try_http_permit(&self) -> Result<OwnedSemaphorePermit, TryAcquireError> {
        Arc::clone(&self.http_permits).try_acquire_owned()
    }

    fn try_websocket_permit(&self) -> Result<OwnedSemaphorePermit, TryAcquireError> {
        Arc::clone(&self.websocket_permits).try_acquire_owned()
    }

    pub(crate) fn admit_unauthenticated_audit(
        &self,
        remote_addr: &str,
    ) -> Result<RemoteUnauthenticatedAuditAdmission, CliError> {
        self.unauthenticated_audit_limiter
            .lock()
            .map_err(|_| {
                CliError::from(CliErrorKind::workflow_io(
                    "remote unauthenticated audit limiter is unavailable",
                ))
            })
            .map(|mut limiter| limiter.admit(remote_addr))
    }

    #[must_use]
    pub(crate) fn unauthenticated_audit_retry_after_seconds(&self) -> u64 {
        let window = self.config.unauthenticated_audit_window;
        window
            .as_secs()
            .saturating_add(u64::from(window.subsec_nanos() != 0))
            .max(1)
    }
}

impl Default for RemoteRequestLimits {
    fn default() -> Self {
        Self::new(RemoteRequestLimitConfig::default()).expect("valid default remote request limits")
    }
}

pub(super) async fn admit_remote_http_request(
    State(state): State<DaemonHttpState>,
    mut request: Request<Body>,
    next: Next,
) -> Response {
    if state.auth_mode == DaemonHttpAuthMode::Local {
        return next.run(request).await;
    }
    request
        .extensions_mut()
        .insert(RemoteHttpAuditMarker::default());
    let (config, permit) = match remote_http_admission(&state, &request) {
        Ok(admission) => admission,
        Err(rejection) => {
            let response = audited_http_limit_response(
                &state,
                RemoteHttpLimitAudit::from_request(&request, &state),
                rejection.status,
                rejection.message,
            )
            .await;
            return rejection.with_response_headers(response);
        }
    };
    let response = run_remote_http_request_with_timeout(&state, request, next, config).await;
    drop(permit);
    response
}

async fn run_remote_http_request_with_timeout(
    state: &DaemonHttpState,
    request: Request<Body>,
    next: Next,
    config: RemoteRequestLimitConfig,
) -> Response {
    let timeout_audit = match RemoteHttpLimitAudit::from_request(&request, state) {
        Ok(audit) => audit,
        Err(response) => return *response,
    };
    match timeout(config.request_timeout, next.run(request)).await {
        Ok(response) => response,
        Err(_) => {
            audited_http_limit_response_from_snapshot(
                state,
                timeout_audit.as_ref(),
                StatusCode::GATEWAY_TIMEOUT,
                "remote request exceeded the configured timeout",
            )
            .await
        }
    }
}

fn remote_http_admission(
    state: &DaemonHttpState,
    request: &Request<Body>,
) -> Result<(RemoteRequestLimitConfig, OwnedSemaphorePermit), RemoteHttpLimitRejection> {
    let Some(limits) = state.remote_request_limits.as_ref() else {
        return Err(RemoteHttpLimitRejection::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "remote request limits are unavailable",
        ));
    };
    let config = limits.config();
    let uri_bytes = request
        .uri()
        .path_and_query()
        .map_or(0, |value| value.as_str().len());
    if uri_bytes > config.max_http_uri_bytes {
        return Err(RemoteHttpLimitRejection::new(
            StatusCode::URI_TOO_LONG,
            "remote request URI exceeds the configured limit",
        ));
    }
    let header_bytes = request
        .headers()
        .iter()
        .fold(0_usize, |total, (name, value)| {
            total
                .saturating_add(name.as_str().len())
                .saturating_add(value.as_bytes().len())
        });
    if header_bytes > config.max_http_header_bytes {
        return Err(RemoteHttpLimitRejection::new(
            StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE,
            "remote request headers exceed the configured limit",
        ));
    }
    let permit = limits.try_http_permit().map_err(|_| {
        RemoteHttpLimitRejection::with_retry_after(
            StatusCode::TOO_MANY_REQUESTS,
            "remote request concurrency limit reached",
        )
    })?;
    Ok((config, permit))
}

#[derive(Debug, Clone, Copy)]
struct RemoteHttpLimitRejection {
    status: StatusCode,
    message: &'static str,
    retry_after: bool,
}

impl RemoteHttpLimitRejection {
    const fn new(status: StatusCode, message: &'static str) -> Self {
        Self {
            status,
            message,
            retry_after: false,
        }
    }

    const fn with_retry_after(status: StatusCode, message: &'static str) -> Self {
        Self {
            status,
            message,
            retry_after: true,
        }
    }

    fn with_response_headers(self, response: Response) -> Response {
        if self.retry_after {
            return with_retry_after(response);
        }
        response
    }
}

pub(super) async fn limit_remote_http_body(
    State(state): State<DaemonHttpState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if state.auth_mode == DaemonHttpAuthMode::Local {
        return next.run(request).await;
    }
    let Some(limits) = state.remote_request_limits.as_ref() else {
        return unavailable_response();
    };
    let max_bytes = effective_remote_http_body_limit(&request, limits.config().max_http_body_bytes);
    if content_length_exceeds(&request, max_bytes) {
        return audited_http_limit_response(
            &state,
            RemoteHttpLimitAudit::from_request(&request, &state),
            StatusCode::PAYLOAD_TOO_LARGE,
            "remote request body exceeds the configured limit",
        )
        .await;
    }
    let (parts, body) = request.into_parts();
    let collected = Limited::new(body, max_bytes).collect().await;
    let Ok(collected) = collected else {
        let rejected = Request::from_parts(parts, Body::empty());
        let audit = RemoteHttpLimitAudit::from_request(&rejected, &state);
        return audited_http_limit_response(
            &state,
            audit,
            StatusCode::PAYLOAD_TOO_LARGE,
            "remote request body exceeds the configured limit",
        )
        .await;
    };
    next.run(Request::from_parts(parts, Body::from(collected.to_bytes())))
        .await
}

fn effective_remote_http_body_limit(request: &Request<Body>, operator_ceiling: usize) -> usize {
    let method = request.method();
    let path = request.uri().path();
    let route_limit = execution_http_body_limit(method, path)
        .or_else(|| policy_transfer_http_body_limit(method, path))
        .unwrap_or(DEFAULT_REMOTE_NON_BULK_HTTP_BODY_LIMIT_BYTES);
    operator_ceiling.min(route_limit)
}

pub(crate) fn prepare_remote_websocket_upgrade(
    ws: WebSocketUpgrade,
    state: &DaemonHttpState,
) -> Result<(WebSocketUpgrade, Option<OwnedSemaphorePermit>), Box<Response>> {
    if state.auth_mode == DaemonHttpAuthMode::Local {
        return Ok((ws, None));
    }
    let limits = state
        .remote_request_limits
        .as_ref()
        .ok_or_else(|| Box::new(unavailable_response()))?;
    let permit = limits.try_websocket_permit().map_err(|_| {
        Box::new(overloaded_response(
            "remote WebSocket connection limit reached",
        ))
    })?;
    let config = limits.config();
    Ok((
        ws.max_message_size(config.max_websocket_message_bytes)
            .max_frame_size(config.max_websocket_frame_bytes),
        Some(permit),
    ))
}

fn content_length_exceeds(request: &Request<Body>, max_bytes: usize) -> bool {
    request
        .headers()
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .is_some_and(|length| length > u64::try_from(max_bytes).unwrap_or(u64::MAX))
}

fn unavailable_response() -> Response {
    limit_response(
        StatusCode::SERVICE_UNAVAILABLE,
        "remote request limits are unavailable",
    )
}

fn overloaded_response(message: &str) -> Response {
    with_retry_after(limit_response(StatusCode::TOO_MANY_REQUESTS, message))
}

fn with_retry_after(mut response: Response) -> Response {
    if response.status() != StatusCode::TOO_MANY_REQUESTS {
        return response;
    }
    response
        .headers_mut()
        .insert(RETRY_AFTER, HeaderValue::from_static("1"));
    response
}

async fn audited_http_limit_response(
    state: &DaemonHttpState,
    audit: Result<Option<RemoteHttpLimitAudit>, Box<Response>>,
    status: StatusCode,
    message: &str,
) -> Response {
    let audit = match audit {
        Ok(audit) => audit,
        Err(response) => return *response,
    };
    audited_http_limit_response_from_snapshot(state, audit.as_ref(), status, message).await
}

async fn audited_http_limit_response_from_snapshot(
    state: &DaemonHttpState,
    audit: Option<&RemoteHttpLimitAudit>,
    status: StatusCode,
    message: &str,
) -> Response {
    let result = match audit {
        Some(audit) => audit.record_rejection(state, message).await,
        None => Ok(()),
    };
    match result {
        Ok(()) => limit_response(status, message),
        Err(response) => *response,
    }
}

fn limit_response(status: StatusCode, message: &str) -> Response {
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

#[cfg(test)]
mod tests;
