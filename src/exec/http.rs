use std::time::{Duration, Instant};

use tracing::info;

use crate::errors::{CliError, CliErrorKind};

use super::runtime::RUNTIME;

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
    let text = RUNTIME.block_on(cp_api_send(&url, method, body, token))?;
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
    RUNTIME.block_on(cp_api_send(&url, method, body, token))
}

fn cp_api_error(url: &str, error: &impl ToString) -> CliError {
    CliErrorKind::cp_api_unreachable(url.to_string()).with_details(error.to_string())
}

async fn cp_api_send(
    url: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<String, CliError> {
    let client = reqwest::Client::new();
    let mut builder = match method {
        HttpMethod::Get => client.get(url),
        HttpMethod::Delete => client.delete(url),
        HttpMethod::Post => client.post(url),
        HttpMethod::Put => client.put(url),
    };
    if let Some(tok) = token {
        builder = builder.bearer_auth(tok);
    }
    if let Some(json) = body {
        builder = builder
            .header("Content-Type", "application/json")
            .json(json);
    }
    let text = builder
        .send()
        .await
        .map_err(|e| cp_api_error(url, &e))?
        .text()
        .await
        .map_err(|e| cp_api_error(url, &e))?;
    Ok(text)
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
    RUNTIME.block_on(wait_for_http_async(url, timeout))
}

async fn wait_for_http_async(url: &str, timeout: Duration) -> Result<(), CliError> {
    use backoff::ExponentialBackoff;
    use backoff::future::retry;

    use std::sync::{Arc, Mutex};
    let client = reqwest::Client::new();
    let start = Instant::now();
    let last_progress: Arc<Mutex<Instant>> = Arc::new(Mutex::new(Instant::now()));
    let cfg = ExponentialBackoff {
        max_elapsed_time: Some(timeout),
        ..ExponentialBackoff::default()
    };
    let url_owned = url.to_string();
    retry(cfg, || {
        let client = client.clone();
        let url = url_owned.clone();
        let elapsed = start.elapsed();
        let last_progress = last_progress.clone();
        async move {
            {
                let mut last = last_progress.lock().expect("lock poisoned");
                if last.elapsed() >= Duration::from_secs(10) {
                    info!(elapsed_seconds = elapsed.as_secs_f64(), "waiting for health check");
                    *last = Instant::now();
                }
            }
            client
                .get(&url)
                .send()
                .await
                .map(|_| ())
                .map_err(backoff::Error::transient)
        }
    })
    .await
    .map_err(|_| CliError::from(CliErrorKind::cp_api_unreachable(url.to_string())))
}
