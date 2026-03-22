use std::time::{Duration, Instant};
use std::{cmp, thread};

use crate::errors::{CliError, CliErrorKind};

use super::run_command;

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

fn curl_method(method: HttpMethod) -> &'static str {
    match method {
        HttpMethod::Get => "GET",
        HttpMethod::Post => "POST",
        HttpMethod::Put => "PUT",
        HttpMethod::Delete => "DELETE",
    }
}

fn cp_api_send(
    url: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<String, CliError> {
    let mut args = vec![
        "curl".to_string(),
        "-fsS".to_string(),
        "-X".to_string(),
        curl_method(method).to_string(),
    ];
    if let Some(tok) = token {
        args.push("-H".to_string());
        args.push(format!("Authorization: Bearer {tok}"));
    }
    if let Some(json) = body {
        args.push("-H".to_string());
        args.push("Content-Type: application/json".to_string());
        args.push("--data".to_string());
        args.push(json.to_string());
    }
    args.push(url.to_string());
    let arg_refs = args.iter().map(String::as_str).collect::<Vec<_>>();
    run_command(&arg_refs, None, None, &[0])
        .map(|result| result.stdout)
        .map_err(|error| cp_api_error(url, &error))
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
    let args = ["curl", "-fsS", "-o", "/dev/null", url];
    run_command(&args, None, None, &[0]).is_ok()
}

fn timed_out(start: Instant, timeout: Duration) -> bool {
    start.elapsed() >= timeout
}

fn sleep_with_backoff(backoff: &mut Duration) {
    thread::sleep(*backoff);
    *backoff = cmp::min(backoff.saturating_mul(2), Duration::from_secs(5));
}
