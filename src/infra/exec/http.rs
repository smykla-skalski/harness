use std::sync::LazyLock;
use std::time::{Duration, Instant};
use std::{cmp, thread};

use crate::errors::{CliError, CliErrorKind};

use super::RUNTIME;

const HTTP_READY_TIMEOUT: Duration = Duration::from_secs(2);
const CP_API_TIMEOUT: Duration = Duration::from_secs(30);

static HTTP_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .build()
        .expect("failed to initialize reqwest client")
});

/// HTTP method for CP API requests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Put,
    Delete,
}

/// Call the CP API and parse the response as JSON.
///
/// # Errors
/// Returns `CliError` on HTTP or parse failure.
pub fn cp_api_json(
    base_url: &str,
    path: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<serde_json::Value, CliError> {
    let url = format!("{base_url}{path}");
    let text = cp_api_send(&url, method, body, token)?;
    serde_json::from_str(&text)
        .map_err(|e| CliErrorKind::cp_api_unreachable(url).with_details(e.to_string()))
}

/// Call the CP API and return the response as a raw string.
///
/// Used for endpoints that return plain text (e.g., token generation).
///
/// # Errors
/// Returns `CliError` on HTTP failure.
pub fn cp_api_text(
    base_url: &str,
    path: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<String, CliError> {
    let url = format!("{base_url}{path}");
    cp_api_send(&url, method, body, token)
}

fn cp_api_error(url: &str, error: &impl ToString) -> CliError {
    CliErrorKind::cp_api_unreachable(url.to_string()).with_details(error.to_string())
}

fn reqwest_method(method: HttpMethod) -> reqwest::Method {
    match method {
        HttpMethod::Get => reqwest::Method::GET,
        HttpMethod::Post => reqwest::Method::POST,
        HttpMethod::Put => reqwest::Method::PUT,
        HttpMethod::Delete => reqwest::Method::DELETE,
    }
}

fn cp_api_send(
    url: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<String, CliError> {
    RUNTIME.block_on(async {
        let mut request = HTTP_CLIENT
            .request(reqwest_method(method), url)
            .timeout(CP_API_TIMEOUT);
        if let Some(tok) = token {
            request = request.bearer_auth(tok);
        }
        if let Some(json) = body {
            request = request.json(json);
        }
        let response = request
            .send()
            .await
            .map_err(|error| cp_api_error(url, &error))?;
        let status = response.status();
        let body_text = response
            .text()
            .await
            .map_err(|error| cp_api_error(url, &error))?;
        if !status.is_success() {
            let detail = if body_text.trim().is_empty() {
                format!("HTTP {status}")
            } else {
                format!("HTTP {status}: {}", body_text.trim())
            };
            return Err(cp_api_error(url, &detail));
        }
        Ok(body_text)
    })
}

/// Wait for an HTTP endpoint to return 200, with exponential backoff.
///
/// Uses `reqwest` for async HTTP and `backoff` for retry logic.
/// Default: starts at 500ms, caps at the given timeout.
/// Emits a progress message every 10 seconds while waiting.
///
/// # Errors
/// Returns `CpApiUnreachable` if the endpoint does not respond within the timeout.
pub fn wait_for_http(url: &str, timeout: Duration) -> Result<(), CliError> {
    let start = Instant::now();
    let mut backoff = Duration::from_millis(500);

    loop {
        if http_ready(url) {
            return Ok(());
        }
        if timed_out(start, timeout) {
            return Err(CliError::from(CliErrorKind::cp_api_unreachable(
                url.to_string(),
            )));
        }
        sleep_with_backoff(&mut backoff);
    }
}

fn http_ready(url: &str) -> bool {
    RUNTIME.block_on(async {
        HTTP_CLIENT
            .get(url)
            .timeout(HTTP_READY_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    })
}

fn timed_out(start: Instant, timeout: Duration) -> bool {
    start.elapsed() >= timeout
}

fn sleep_with_backoff(backoff: &mut Duration) {
    thread::sleep(*backoff);
    *backoff = cmp::min(backoff.saturating_mul(2), Duration::from_secs(5));
}
