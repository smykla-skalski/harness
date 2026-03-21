use std::time::Duration;

use crate::infra::blocks::BlockError;
use crate::infra::exec;

use super::types::{HttpMethod, HttpResponse};

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

    fn request_builder(&self, method: HttpMethod, url: &str) -> reqwest::RequestBuilder {
        match method {
            HttpMethod::Get => self.client.get(url),
            HttpMethod::Post => self.client.post(url),
            HttpMethod::Put => self.client.put(url),
            HttpMethod::Delete => self.client.delete(url),
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
            let mut builder = self.request_builder(method, url);
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
