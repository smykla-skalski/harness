#[cfg(test)]
use std::sync;
use std::time::Duration;

use crate::blocks::BlockError;
use crate::exec;

/// HTTP method for API requests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Put,
    Delete,
}

/// HTTP response from a block operation.
#[derive(Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
}

/// HTTP client for REST APIs and health checks.
pub trait HttpClient: Send + Sync {
    /// Make an HTTP request, return response body as string.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the request fails or the server is unreachable.
    fn request(
        &self,
        method: HttpMethod,
        url: &str,
        body: Option<&serde_json::Value>,
        headers: &[(&str, &str)],
    ) -> Result<HttpResponse, BlockError>;

    /// Make an HTTP request, parse response as JSON.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the request fails or the response is not valid JSON.
    fn request_json(
        &self,
        method: HttpMethod,
        url: &str,
        body: Option<&serde_json::Value>,
        headers: &[(&str, &str)],
    ) -> Result<serde_json::Value, BlockError> {
        let response = self.request(method, url, body, headers)?;
        serde_json::from_str(&response.body).map_err(|e| BlockError::new("http", url, e))
    }

    /// Poll URL until successful response or timeout.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the URL does not become ready within the timeout.
    fn wait_until_ready(&self, url: &str, timeout: Duration) -> Result<(), BlockError>;
}

pub struct ReqwestHttpClient {
    client: reqwest::Client,
}

impl ReqwestHttpClient {
    #[must_use]
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::new(),
        }
    }
}

impl Default for ReqwestHttpClient {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpClient for ReqwestHttpClient {
    fn request(
        &self,
        method: HttpMethod,
        url: &str,
        body: Option<&serde_json::Value>,
        headers: &[(&str, &str)],
    ) -> Result<HttpResponse, BlockError> {
        exec::RUNTIME.block_on(async {
            let mut builder = match method {
                HttpMethod::Get => self.client.get(url),
                HttpMethod::Post => self.client.post(url),
                HttpMethod::Put => self.client.put(url),
                HttpMethod::Delete => self.client.delete(url),
            };
            for (key, value) in headers {
                builder = builder.header(*key, *value);
            }
            if let Some(json) = body {
                builder = builder
                    .header("Content-Type", "application/json")
                    .json(json);
            }
            let response = builder
                .send()
                .await
                .map_err(|e| BlockError::new("http", url, e))?;
            let status = response.status().as_u16();
            let body_text = response
                .text()
                .await
                .map_err(|e| BlockError::new("http", url, e))?;
            Ok(HttpResponse {
                status,
                body: body_text,
            })
        })
    }

    fn wait_until_ready(&self, url: &str, timeout: Duration) -> Result<(), BlockError> {
        exec::wait_for_http(url, timeout)
            .map_err(|e| BlockError::new("http", &format!("wait_until_ready {url}"), e))
    }
}

#[cfg(test)]
pub struct FakeHttpClient {
    responses: sync::Mutex<Vec<FakeHttpResponse>>,
}

#[cfg(test)]
pub struct FakeHttpResponse {
    pub status: u16,
    pub body: String,
}

#[cfg(test)]
impl FakeHttpClient {
    #[must_use]
    pub fn new(responses: Vec<FakeHttpResponse>) -> Self {
        Self {
            responses: sync::Mutex::new(responses),
        }
    }

    #[must_use]
    pub fn single(status: u16, body: &str) -> Self {
        Self::new(vec![FakeHttpResponse {
            status,
            body: body.to_string(),
        }])
    }
}

#[cfg(test)]
impl HttpClient for FakeHttpClient {
    fn request(
        &self,
        _method: HttpMethod,
        _url: &str,
        _body: Option<&serde_json::Value>,
        _headers: &[(&str, &str)],
    ) -> Result<HttpResponse, BlockError> {
        let mut responses = self.responses.lock().expect("lock poisoned");
        assert!(!responses.is_empty(), "FakeHttpClient: no responses left");
        let response = responses.remove(0);
        Ok(HttpResponse {
            status: response.status,
            body: response.body,
        })
    }

    fn wait_until_ready(&self, _url: &str, _timeout: Duration) -> Result<(), BlockError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::thread;

    use super::*;

    fn mock_http_server(
        response_body: &str,
        content_type: &str,
    ) -> (u16, thread::JoinHandle<String>) {
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
}
