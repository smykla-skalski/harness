use std::time::Instant;

use serde::de::DeserializeOwned;
use serde_json::Value;
use uuid::Uuid;

use super::{DaemonClient, MUTATION_TIMEOUT};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;

impl DaemonClient {
    pub(super) fn get<Res: DeserializeOwned>(&self, path: &str) -> Result<Res, CliError> {
        let request_id = Uuid::new_v4().to_string();
        let start = Instant::now();
        let url = format!("{}{path}", self.endpoint);
        let response = RUNTIME.block_on(async {
            self.http
                .get(&url)
                .bearer_auth(&self.token)
                .header("x-request-id", &request_id)
                .timeout(MUTATION_TIMEOUT)
                .send()
                .await
        });
        process_response(response, "GET", path, &request_id, &start)
    }

    pub(super) fn post<Req: serde::Serialize, Res: DeserializeOwned>(
        &self,
        path: &str,
        body: &Req,
    ) -> Result<Res, CliError> {
        let request_id = Uuid::new_v4().to_string();
        let start = Instant::now();
        let url = format!("{}{path}", self.endpoint);
        let response = RUNTIME.block_on(async {
            self.http
                .post(&url)
                .bearer_auth(&self.token)
                .header("x-request-id", &request_id)
                .json(body)
                .timeout(MUTATION_TIMEOUT)
                .send()
                .await
        });
        process_response(response, "POST", path, &request_id, &start)
    }
}

fn process_response<Res: DeserializeOwned>(
    response: Result<reqwest::Response, reqwest::Error>,
    method: &str,
    path: &str,
    request_id: &str,
    start: &Instant,
) -> Result<Res, CliError> {
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
    if is_error {
        log_client_warn(method, path, status, duration_ms, request_id);
    } else {
        log_client_debug(method, path, status, duration_ms, request_id);
    }
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
