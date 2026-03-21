use std::time::Duration;

use harness::infra::blocks::{HttpClient, HttpMethod};

/// A GET request returns a response with a status code and body.
///
/// # Panics
/// Panics if the request fails or returns an unexpected status.
pub fn contract_request_returns_response(client: &dyn HttpClient) {
    let response = client
        .request(HttpMethod::Get, "http://httpbin.org/get", None, &[])
        .expect("GET should succeed");
    assert!(
        response.status >= 200 && response.status < 400,
        "expected 2xx/3xx status, got {}",
        response.status
    );
    assert!(!response.body.is_empty(), "body should not be empty");
}

/// `request_json` parses a JSON response into a `serde_json::Value`.
///
/// # Panics
/// Panics if the request fails or response is not valid JSON.
pub fn contract_request_json_parses_body(client: &dyn HttpClient) {
    let value = client
        .request_json(HttpMethod::Get, "http://httpbin.org/get", None, &[])
        .expect("GET JSON should succeed");
    assert!(value.is_object(), "expected JSON object");
}

/// `wait_until_ready` returns an error when the target is unreachable.
///
/// # Panics
/// Panics if the client does not return an error for the unreachable URL.
pub fn contract_wait_until_ready_times_out_on_unreachable(client: &dyn HttpClient) {
    let result = client.wait_until_ready("http://127.0.0.1:1", Duration::from_millis(200));
    assert!(result.is_err(), "unreachable URL should time out");
}

#[cfg(test)]
mod tests;
