use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::thread;
use std::time::Duration;

use super::*;

fn mock_http_server(response_body: &str, content_type: &str) -> (u16, thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let body = response_body.to_string();
    let ct = content_type.to_string();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buf = [0u8; 4096];
        let n = stream.read(&mut buf).unwrap_or(0);
        let request = String::from_utf8_lossy(&buf[..n]).to_string();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).ok();
        request
    });
    (port, handle)
}

#[test]
fn reqwest_http_client_get_returns_body() {
    let (port, _handle) = mock_http_server("plain text response", "text/plain");
    let url = format!("http://127.0.0.1:{port}");
    let client = ReqwestHttpClient::new();
    let response = client
        .request(HttpMethod::Get, &url, None, &[])
        .expect("expected response");
    assert_eq!(response.status, 200);
    assert_eq!(response.body, "plain text response");
}

#[test]
fn reqwest_http_client_post_sends_json_content_type() {
    let (port, handle) = mock_http_server("{}", "application/json");
    let url = format!("http://127.0.0.1:{port}");
    let client = ReqwestHttpClient::new();
    let body = serde_json::json!({ "key": "value" });
    let _ = client
        .request(HttpMethod::Post, &url, Some(&body), &[])
        .expect("expected response");
    let request = handle.join().unwrap();
    let lower = request.to_lowercase();
    assert!(
        lower.contains("content-type: application/json"),
        "request should include content-type header, got: {request}"
    );
    assert!(
        request.contains(r#""key":"value""#),
        "request should include JSON body, got: {request}"
    );
}

#[test]
fn reqwest_http_client_includes_auth_header() {
    let (port, handle) = mock_http_server("{}", "application/json");
    let url = format!("http://127.0.0.1:{port}");
    let client = ReqwestHttpClient::new();
    let _ = client
        .request(
            HttpMethod::Get,
            &url,
            None,
            &[("Authorization", "Bearer my-token")],
        )
        .expect("expected response");
    let request = handle.join().unwrap();
    let lower = request.to_lowercase();
    assert!(
        lower.contains("authorization: bearer my-token"),
        "request should contain auth header, got: {request}"
    );
}

#[test]
fn reqwest_http_client_request_json_parses_body() {
    let (port, _handle) = mock_http_server(r#"{"key":"value"}"#, "application/json");
    let url = format!("http://127.0.0.1:{port}");
    let client = ReqwestHttpClient::new();
    let result = client
        .request_json(HttpMethod::Get, &url, None, &[])
        .expect("expected json");
    assert_eq!(result["key"], "value");
}

#[test]
fn reqwest_http_client_request_json_errors_on_invalid_json() {
    let (port, _handle) = mock_http_server("not json", "text/plain");
    let url = format!("http://127.0.0.1:{port}");
    let client = ReqwestHttpClient::new();
    let result = client.request_json(HttpMethod::Get, &url, None, &[]);
    assert!(result.is_err());
}

#[test]
fn reqwest_http_client_wait_until_ready_times_out() {
    let client = ReqwestHttpClient::new();
    let result = client.wait_until_ready("http://127.0.0.1:1", Duration::from_millis(200));
    assert!(result.is_err());
}

#[test]
fn fake_http_client_returns_canned_response() {
    let client = FakeHttpClient::single(200, "ok");
    let response = client
        .request(HttpMethod::Get, "http://example.com", None, &[])
        .expect("expected response");
    assert_eq!(response.status, 200);
    assert_eq!(response.body, "ok");
}

#[test]
fn fake_http_client_request_json_parses_body() {
    let client = FakeHttpClient::single(200, r#"{"key":"value"}"#);
    let response = client
        .request_json(HttpMethod::Get, "http://example.com", None, &[])
        .expect("expected json");
    assert_eq!(response["key"], "value");
}

#[test]
fn fake_http_client_request_json_errors_on_invalid_json() {
    let client = FakeHttpClient::single(200, "not json");
    let result = client.request_json(HttpMethod::Get, "http://example.com", None, &[]);
    assert!(result.is_err());
}

#[test]
fn fake_http_client_is_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<FakeHttpClient>();
}

// -- Contract tests: fake satisfies the same invariants as production --

mod contracts {
    use super::*;

    fn contract_request_returns_response(client: &dyn HttpClient) {
        let response = client
            .request(HttpMethod::Get, "http://example.com/get", None, &[])
            .expect("GET should succeed");
        assert!(
            response.status >= 200 && response.status < 400,
            "expected 2xx/3xx status, got {}",
            response.status
        );
        assert!(!response.body.is_empty(), "body should not be empty");
    }

    fn contract_request_json_parses_body(client: &dyn HttpClient) {
        let value = client
            .request_json(HttpMethod::Get, "http://example.com/get", None, &[])
            .expect("GET JSON should succeed");
        assert!(value.is_object(), "expected JSON object");
    }

    fn contract_wait_until_ready_times_out(client: &dyn HttpClient) {
        let result = client.wait_until_ready("http://127.0.0.1:1", Duration::from_millis(200));
        assert!(result.is_err(), "unreachable URL should time out");
    }

    #[test]
    fn fake_satisfies_request_returns_response() {
        let client = FakeHttpClient::single(200, "hello from fake");
        contract_request_returns_response(&client);
    }

    #[test]
    fn fake_satisfies_request_json_parses_body() {
        let client = FakeHttpClient::single(200, r#"{"url":"http://example.com"}"#);
        contract_request_json_parses_body(&client);
    }

    #[test]
    #[ignore = "needs network access"]
    fn production_satisfies_request_returns_response() {
        contract_request_returns_response(&ReqwestHttpClient::new());
    }

    #[test]
    #[ignore = "needs network access"]
    fn production_satisfies_wait_until_ready_times_out() {
        contract_wait_until_ready_times_out(&ReqwestHttpClient::new());
    }
}
