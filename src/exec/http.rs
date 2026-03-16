use std::time::{Duration, Instant};

use ureq::Body;
use ureq::http::Response;

use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind};

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

/// Apply an optional bearer token to any ureq `RequestBuilder` type.
///
/// ureq v3 uses distinct typestates (`WithBody` / `WithoutBody`) so we cannot
/// pass the builder through a single generic helper. A macro keeps the auth
/// logic in one place without duplicating the `if let` across every match arm.
macro_rules! with_bearer_auth {
    ($request:expr, $auth_header:expr) => {{
        let mut request = $request;
        if let Some(auth) = $auth_header {
            request = request.header("Authorization", auth.to_string());
        }
        request
    }};
}

/// Build, send, and read the full response body as a string from the CP API.
fn cp_api_send(
    url: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<String, CliError> {
    let auth_header = token.map(|tok| format!("Bearer {tok}"));
    match method {
        HttpMethod::Get => cp_api_get(url, auth_header.as_deref()),
        HttpMethod::Delete => cp_api_delete(url, auth_header.as_deref()),
        HttpMethod::Post => cp_api_post(url, body, auth_header.as_deref()),
        HttpMethod::Put => cp_api_put(url, body, auth_header.as_deref()),
    }
}

fn cp_api_error(url: &str, error: &impl ToString) -> CliError {
    CliErrorKind::cp_api_unreachable(url.to_string()).with_details(error.to_string())
}

fn read_cp_api_body(url: &str, mut response: Response<Body>) -> Result<String, CliError> {
    response
        .body_mut()
        .read_to_string()
        .map_err(|error| cp_api_error(url, &error))
}

fn cp_api_get(url: &str, auth_header: Option<&str>) -> Result<String, CliError> {
    let response = with_bearer_auth!(ureq::get(url), auth_header)
        .call()
        .map_err(|error| cp_api_error(url, &error))?;
    read_cp_api_body(url, response)
}

fn cp_api_delete(url: &str, auth_header: Option<&str>) -> Result<String, CliError> {
    let response = with_bearer_auth!(ureq::delete(url), auth_header)
        .call()
        .map_err(|error| cp_api_error(url, &error))?;
    read_cp_api_body(url, response)
}

fn cp_api_post(
    url: &str,
    body: Option<&serde_json::Value>,
    auth_header: Option<&str>,
) -> Result<String, CliError> {
    let response = match body {
        Some(json) => with_bearer_auth!(
            ureq::post(url).header("Content-Type", "application/json"),
            auth_header
        )
        .send_json(json)
        .map_err(|error| cp_api_error(url, &error))?,
        None => with_bearer_auth!(ureq::post(url), auth_header)
            .send_empty()
            .map_err(|error| cp_api_error(url, &error))?,
    };
    read_cp_api_body(url, response)
}

fn cp_api_put(
    url: &str,
    body: Option<&serde_json::Value>,
    auth_header: Option<&str>,
) -> Result<String, CliError> {
    let response = match body {
        Some(json) => with_bearer_auth!(
            ureq::put(url).header("Content-Type", "application/json"),
            auth_header
        )
        .send_json(json)
        .map_err(|error| cp_api_error(url, &error))?,
        None => with_bearer_auth!(ureq::put(url), auth_header)
            .send_empty()
            .map_err(|error| cp_api_error(url, &error))?,
    };
    read_cp_api_body(url, response)
}

/// Wait for an HTTP endpoint to return 200, with exponential backoff.
///
/// Uses `ureq` for sync HTTP and `backoff` for retry logic.
/// Default: starts at 500ms, caps at the given timeout.
/// Emits a progress message every 10 seconds while waiting.
///
/// # Errors
/// Returns `CpApiUnreachable` if the endpoint does not respond within the timeout.
pub fn wait_for_http(url: &str, timeout: Duration) -> Result<(), CliError> {
    use backoff::ExponentialBackoff;

    let backoff_config = ExponentialBackoff {
        max_elapsed_time: Some(timeout),
        ..ExponentialBackoff::default()
    };
    let start = Instant::now();
    let mut last_progress = Instant::now();
    backoff::retry(backoff_config, || {
        let elapsed = start.elapsed();
        if last_progress.elapsed() >= Duration::from_secs(10) {
            let ts = utc_now();
            eprintln!(
                "    {ts} cluster: waiting for health check ({:.0}s elapsed)",
                elapsed.as_secs_f64()
            );
            last_progress = Instant::now();
        }
        ureq::get(url)
            .call()
            .map(|_| ())
            .map_err(backoff::Error::transient)
    })
    .map_err(|_| CliError::from(CliErrorKind::cp_api_unreachable(url.to_string())))
}
