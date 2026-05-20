//! Async HTTP client for `OpenRouter` chat completions and model listing.
//!
//! Streaming uses SSE per the `OpenRouter` docs. Each event line is `data: …`;
//! `data: [DONE]` terminates the stream and comment lines (`: keep-alive`)
//! are filtered before JSON parse. Headers include `HTTP-Referer` and
//! `X-Title` so traffic shows up under the harness identity on `OpenRouter`'s
//! analytics dashboard.

use std::pin::Pin;
use std::str::from_utf8;
use std::time::Duration;

use async_stream::try_stream;
use futures_util::Stream;
use reqwest::{Client, header};
use tracing::warn;

use super::errors::{OpenRouterError, classify_status, parse_retry_after};
use super::types::{ChatRequest, ModelListResponse, StreamChunk};

/// Default network timeout for non-streaming calls. Streaming has no overall
/// timeout because long thinking turns must be allowed to run; idle reads
/// still bubble up as transport errors via reqwest's per-chunk poll.
const NON_STREAMING_TIMEOUT: Duration = Duration::from_mins(1);

#[derive(Debug, Clone)]
pub struct OpenRouterClient {
    http: Client,
    base_url: String,
    api_key: String,
    http_referer: String,
    x_title: String,
}

impl OpenRouterClient {
    /// Build a new client.
    ///
    /// # Errors
    /// Returns an error when reqwest cannot initialize (rare; surfaces TLS or
    /// resolver init failures).
    pub fn new(
        base_url: impl Into<String>,
        api_key: impl Into<String>,
        http_referer: impl Into<String>,
        x_title: impl Into<String>,
    ) -> Result<Self, OpenRouterError> {
        let http = Client::builder()
            .user_agent(concat!("harness/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(OpenRouterError::Transport)?;
        Ok(Self {
            http,
            base_url: base_url.into(),
            api_key: api_key.into(),
            http_referer: http_referer.into(),
            x_title: x_title.into(),
        })
    }

    /// Issue a streaming chat completion request. The returned stream yields
    /// parsed [`StreamChunk`] values until the SSE `[DONE]` sentinel.
    ///
    /// # Errors
    /// Returns early errors when the request cannot be built, when the
    /// initial HTTP exchange fails, or when the server responds with a
    /// non-2xx status. Per-chunk decode failures surface inside the stream.
    pub async fn stream_chat(
        &self,
        request: ChatRequest,
    ) -> Result<
        Pin<Box<dyn Stream<Item = Result<StreamChunk, OpenRouterError>> + Send>>,
        OpenRouterError,
    > {
        let url = format!("{}/chat/completions", self.base_url.trim_end_matches('/'));
        let response = self
            .http
            .post(&url)
            .bearer_auth(&self.api_key)
            .header(header::ACCEPT, "text/event-stream")
            .header("HTTP-Referer", &self.http_referer)
            .header("X-Title", &self.x_title)
            .json(&request)
            .send()
            .await
            .map_err(OpenRouterError::Transport)?;

        if !response.status().is_success() {
            return Err(error_from_response(response).await);
        }

        let stream = try_stream! {
            let mut response = response;
            let mut buffer = Vec::<u8>::new();
            while let Some(bytes) = response
                .chunk()
                .await
                .map_err(OpenRouterError::Transport)?
            {
                buffer.extend_from_slice(&bytes);
                while let Some(newline) = buffer.iter().position(|b| *b == b'\n') {
                    let line: Vec<u8> = buffer.drain(..=newline).collect();
                    let trimmed = trim_trailing_ascii(&line);
                    if trimmed.is_empty() || trimmed.starts_with(b":") {
                        continue;
                    }
                    let Some(payload) = trimmed.strip_prefix(b"data: ") else {
                        if let Ok(text) = from_utf8(trimmed) {
                            warn!(line = %text, "ignoring non-data SSE line");
                        }
                        continue;
                    };
                    if payload == b"[DONE]" {
                        return;
                    }
                    let chunk: StreamChunk = serde_json::from_slice(payload)
                        .map_err(OpenRouterError::Deserialize)?;
                    yield chunk;
                }
            }
        };
        Ok(Box::pin(stream))
    }

    /// Fetch the per-key model list (`GET /models/user`).
    ///
    /// # Errors
    /// Returns transport errors, non-2xx statuses, or deserialization errors.
    pub async fn list_models(&self) -> Result<ModelListResponse, OpenRouterError> {
        let url = format!("{}/models/user", self.base_url.trim_end_matches('/'));
        let response = self
            .http
            .get(&url)
            .bearer_auth(&self.api_key)
            .header("HTTP-Referer", &self.http_referer)
            .header("X-Title", &self.x_title)
            .timeout(NON_STREAMING_TIMEOUT)
            .send()
            .await
            .map_err(OpenRouterError::Transport)?;

        if !response.status().is_success() {
            return Err(error_from_response(response).await);
        }
        let body = response.bytes().await.map_err(OpenRouterError::ReadBody)?;
        serde_json::from_slice(&body).map_err(OpenRouterError::Deserialize)
    }
}

async fn error_from_response(response: reqwest::Response) -> OpenRouterError {
    let status = response.status().as_u16();
    let retry_after = response
        .headers()
        .get("retry-after")
        .or_else(|| response.headers().get("x-ratelimit-reset"))
        .and_then(|value| value.to_str().ok())
        .and_then(parse_retry_after);
    let body = match response.text().await {
        Ok(body) => body,
        Err(error) => format!("<failed to read body: {error}>"),
    };
    classify_status(status, retry_after, body)
}

fn trim_trailing_ascii(bytes: &[u8]) -> &[u8] {
    let mut end = bytes.len();
    while end > 0 && matches!(bytes[end - 1], b'\n' | b'\r' | b' ' | b'\t') {
        end -= 1;
    }
    &bytes[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_carriage_return_and_newline() {
        assert_eq!(trim_trailing_ascii(b"data: x\r\n"), b"data: x");
        assert_eq!(trim_trailing_ascii(b"data: x\n"), b"data: x");
        assert_eq!(trim_trailing_ascii(b""), b"");
    }
}
