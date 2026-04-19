use std::time::Instant;

use serde::de::DeserializeOwned;
use serde_json::Value;
use tracing::field::{Empty, display};
use uuid::Uuid;

use super::{DaemonClient, MUTATION_TIMEOUT};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;
use crate::telemetry::{current_trace_headers, current_trace_id, record_daemon_client_metrics};

impl DaemonClient {
    pub(super) fn get<Res: DeserializeOwned>(&self, path: &str) -> Result<Res, CliError> {
        let request_id = Uuid::new_v4().to_string();
        let start = Instant::now();
        let url = format!("{}{path}", self.endpoint);
        let span = client_request_span("GET", path, &request_id, &self.endpoint);
        let _guard = span.enter();
        record_trace_id(&span);
        let propagation_headers = current_trace_headers();
        let response = RUNTIME.block_on(async {
            let mut request = self
                .http
                .get(&url)
                .bearer_auth(&self.token)
                .header("x-request-id", &request_id)
                .timeout(MUTATION_TIMEOUT);
            for (header, value) in &propagation_headers {
                request = request.header(header, value);
            }
            request.send().await
        });
        process_response(response, "GET", path, &request_id, &start)
    }

    /// GET that treats HTTP 404 as a distinct "endpoint absent" signal
    /// (returned as `Ok(None)`), used when the client wants to detect a
    /// missing new endpoint on an older daemon without conflating it with
    /// other failures.
    pub(super) fn get_optional<Res: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<Option<Res>, CliError> {
        let request_id = Uuid::new_v4().to_string();
        let start = Instant::now();
        let url = format!("{}{path}", self.endpoint);
        let span = client_request_span("GET", path, &request_id, &self.endpoint);
        let _guard = span.enter();
        record_trace_id(&span);
        let propagation_headers = current_trace_headers();
        let response = RUNTIME.block_on(async {
            let mut request = self
                .http
                .get(&url)
                .bearer_auth(&self.token)
                .header("x-request-id", &request_id)
                .query(query)
                .timeout(MUTATION_TIMEOUT);
            for (header, value) in &propagation_headers {
                request = request.header(header, value);
            }
            request.send().await
        });
        process_optional_response(response, "GET", path, &request_id, &start)
    }

    pub(super) fn post<Req: serde::Serialize, Res: DeserializeOwned>(
        &self,
        path: &str,
        body: &Req,
    ) -> Result<Res, CliError> {
        let request_id = Uuid::new_v4().to_string();
        let start = Instant::now();
        let url = format!("{}{path}", self.endpoint);
        let span = client_request_span("POST", path, &request_id, &self.endpoint);
        let _guard = span.enter();
        record_trace_id(&span);
        let propagation_headers = current_trace_headers();
        let response = RUNTIME.block_on(async {
            let mut request = self
                .http
                .post(&url)
                .bearer_auth(&self.token)
                .header("x-request-id", &request_id)
                .json(body)
                .timeout(MUTATION_TIMEOUT);
            for (header, value) in &propagation_headers {
                request = request.header(header, value);
            }
            request.send().await
        });
        process_response(response, "POST", path, &request_id, &start)
    }
}

fn process_optional_response<Res: DeserializeOwned>(
    response: Result<reqwest::Response, reqwest::Error>,
    method: &str,
    path: &str,
    request_id: &str,
    start: &Instant,
) -> Result<Option<Res>, CliError> {
    let span = tracing::Span::current();
    let response = response.map_err(|error| {
        log_client_request(method, path, 0, start, request_id, true);
        CliErrorKind::workflow_io(format!("daemon HTTP request failed: {error}"))
    })?;

    let status = response.status().as_u16();
    if status == 404 {
        log_client_request(method, path, status, start, request_id, false);
        let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
        span.record("http_status_code", display(status));
        span.record("http.response.status_code", display(status));
        span.record("duration_ms", display(duration_ms));
        span.record("error", display(false));
        span.record("request.failed", display(false));
        return Ok(None);
    }

    let body_text = RUNTIME
        .block_on(response.text())
        .map_err(|error| CliErrorKind::workflow_io(format!("daemon HTTP read body: {error}")))?;

    let failed = !(200..300).contains(&status);
    log_client_request(method, path, status, start, request_id, failed);
    let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    span.record("http_status_code", display(status));
    span.record("http.response.status_code", display(status));
    span.record("duration_ms", display(duration_ms));
    span.record("error", display(failed));
    span.record("request.failed", display(failed));

    if failed {
        return Err(parse_error_response(&body_text, status));
    }

    serde_json::from_str(&body_text).map(Some).map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon HTTP parse response: {error}")).into()
    })
}

fn process_response<Res: DeserializeOwned>(
    response: Result<reqwest::Response, reqwest::Error>,
    method: &str,
    path: &str,
    request_id: &str,
    start: &Instant,
) -> Result<Res, CliError> {
    let span = tracing::Span::current();
    let response = response.map_err(|error| {
        log_client_request(method, path, 0, start, request_id, true);
        CliErrorKind::workflow_io(format!("daemon HTTP request failed: {error}"))
    })?;

    let status = response.status().as_u16();
    let body_text = RUNTIME
        .block_on(response.text())
        .map_err(|error| CliErrorKind::workflow_io(format!("daemon HTTP read body: {error}")))?;

    let failed = !(200..300).contains(&status);
    log_client_request(method, path, status, start, request_id, failed);
    let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    span.record("http_status_code", display(status));
    span.record("http.response.status_code", display(status));
    span.record("duration_ms", display(duration_ms));
    span.record("error", display(failed));
    span.record("request.failed", display(failed));

    if failed {
        return Err(parse_error_response(&body_text, status));
    }

    serde_json::from_str(&body_text).map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon HTTP parse response: {error}")).into()
    })
}

fn log_client_request(
    method: &str,
    path: &str,
    status: u16,
    start: &Instant,
    request_id: &str,
    is_error: bool,
) {
    let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    record_daemon_client_metrics(method, path, status, duration_ms, is_error);
    if is_error {
        log_client_warn(method, path, status, duration_ms, request_id);
    } else {
        log_client_debug(method, path, status, duration_ms, request_id);
    }
}

fn record_trace_id(span: &tracing::Span) {
    if let Some(trace_id) = current_trace_id() {
        span.record("trace_id", display(trace_id));
    }
}

fn client_request_span(
    method: &str,
    path: &str,
    request_id: &str,
    endpoint: &str,
) -> tracing::Span {
    let otel_name = format!("{method} {path}");
    let parsed_endpoint = reqwest::Url::parse(endpoint).ok();
    tracing::info_span!(
        "harness.daemon.client.request",
        otel.name = %otel_name,
        otel.kind = "client",
        http_method = %method,
        http_route = %path,
        request_id = %request_id,
        "http.request.method" = %method,
        "http.route" = %path,
        "url.path" = %path,
        "server.address" = parsed_endpoint
            .as_ref()
            .and_then(reqwest::Url::host_str)
            .unwrap_or(""),
        "server.port" = parsed_endpoint
            .as_ref()
            .and_then(reqwest::Url::port_or_known_default)
            .unwrap_or(0),
        "http.response.status_code" = Empty,
        http_status_code = Empty,
        duration_ms = Empty,
        trace_id = Empty,
        "request.failed" = Empty,
        error = Empty
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_client_warn(method: &str, path: &str, status: u16, duration_ms: u64, request_id: &str) {
    tracing::warn!(
        method,
        path,
        status,
        duration_ms,
        request_id,
        "daemon client request failed"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_client_debug(method: &str, path: &str, status: u16, duration_ms: u64, request_id: &str) {
    tracing::debug!(
        method,
        path,
        status,
        duration_ms,
        request_id,
        "daemon client request"
    );
}

pub(super) fn parse_error_response(body: &str, status: u16) -> CliError {
    if let Ok(parsed) = serde_json::from_str::<Value>(body)
        && let Some(error) = parsed.get("error")
    {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("daemon returned an error");
        let code = error
            .get("code")
            .and_then(Value::as_str)
            .unwrap_or("DAEMON_ERROR");
        return CliErrorKind::workflow_io(format!(
            "daemon error ({code}, HTTP {status}): {message}"
        ))
        .into();
    }
    CliErrorKind::workflow_io(format!("daemon HTTP {status}: {body}")).into()
}
