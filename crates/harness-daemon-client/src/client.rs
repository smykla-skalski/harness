use std::fs;
use std::thread;
use std::time::{Duration, Instant};

use reqwest::StatusCode;
use reqwest::blocking::{Client, RequestBuilder, Response};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::discovery;
use crate::state::{self, DaemonManifest};

const HEALTH_TIMEOUT: Duration = Duration::from_millis(500);
const API_READY_TIMEOUT: Duration = Duration::from_secs(2);
const API_READY_INTERVAL: Duration = Duration::from_millis(100);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
const SESSION_START_TIMEOUT: Duration = Duration::from_secs(30);
const TASK_BOARD_OPERATION_TIMEOUT: Duration = Duration::from_mins(2);

#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("build daemon HTTP client: {0}")]
    Build(reqwest::Error),
    #[error("read daemon auth token {}: {source}", path.display())]
    ReadToken {
        path: std::path::PathBuf,
        source: std::io::Error,
    },
    #[error("daemon auth token is empty: {}", path.display())]
    EmptyToken { path: std::path::PathBuf },
    #[error("daemon HTTP request failed: {0}")]
    Request(reqwest::Error),
    #[error("{}", response_display_message(method, path, *status, body))]
    Response {
        method: &'static str,
        path: String,
        status: u16,
        body: String,
    },
    #[error("decode daemon HTTP {method} {path} response: {source}")]
    Decode {
        method: &'static str,
        path: String,
        source: serde_json::Error,
    },
}

/// Parses the daemon's `{"error":{"code","message"}}` envelope out of a
/// non-success response body, mirroring the root facade's
/// `daemon::client::http::parse_error_response`. Every caller that formats a
/// `ClientError::Response` through `Display` - directly or via a
/// `daemon_client_error`-style wrapper - gets the same clean message instead
/// of a raw JSON dump; falls back to the full method/path/status/body when
/// the envelope is missing or malformed.
fn response_display_message(method: &str, path: &str, status: u16, body: &str) -> String {
    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(body)
        && let Some(error) = parsed.get("error")
    {
        let message = error
            .get("message")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("daemon returned an error");
        let code = error
            .get("code")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("DAEMON_ERROR");
        return format!("daemon error ({code}, HTTP {status}): {message}");
    }
    format!("daemon HTTP {method} {path} returned {status}: {body}")
}

/// Authenticated synchronous client for a live Harness daemon.
pub struct DaemonClient {
    endpoint: String,
    token: String,
    http: Client,
}

impl DaemonClient {
    /// Discover a live daemon and verify both health and authenticated API readiness.
    #[must_use]
    pub fn try_connect() -> Option<Self> {
        let _ = discovery::adopt_running_daemon_root();
        let manifest = state::load_running_manifest().ok().flatten()?;
        let client = Self::from_manifest(&manifest).ok()?;
        if client.health_is_ready() && client.authenticated_api_is_ready(API_READY_TIMEOUT) {
            tracing::debug!(endpoint = client.endpoint(), "daemon client connected");
            Some(client)
        } else {
            tracing::debug!(
                endpoint = client.endpoint(),
                "daemon client readiness failed"
            );
            None
        }
    }

    #[must_use]
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    #[must_use]
    pub fn token(&self) -> &str {
        &self.token
    }

    /// Perform an authenticated GET, returning `None` for HTTP 404.
    ///
    /// # Errors
    /// Returns [`ClientError`] on transport, non-success status, or decode failure.
    pub fn get_optional<T>(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<Option<T>, ClientError>
    where
        T: DeserializeOwned,
    {
        let response = self
            .request(self.http.get(self.url(path)).query(query))
            .send()
            .map_err(ClientError::Request)?;
        if response.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        Self::decode(response, "GET", path).map(Some)
    }

    /// Perform an authenticated GET and decode its JSON response.
    ///
    /// # Errors
    /// Returns [`ClientError`] on transport, non-success status, or decode failure.
    pub fn get<T>(&self, path: &str, query: &[(&str, &str)]) -> Result<T, ClientError>
    where
        T: DeserializeOwned,
    {
        self.get_optional(path, query)?
            .ok_or_else(|| ClientError::Response {
                method: "GET",
                path: path.to_string(),
                status: StatusCode::NOT_FOUND.as_u16(),
                body: "not found".to_string(),
            })
    }

    /// Perform an authenticated POST and decode its JSON response.
    ///
    /// # Errors
    /// Returns [`ClientError`] on transport, non-success status, or decode failure.
    pub fn post<Request, Response>(
        &self,
        path: &str,
        request: &Request,
    ) -> Result<Response, ClientError>
    where
        Request: Serialize + ?Sized,
        Response: DeserializeOwned,
    {
        let response = self
            .request(
                self.http
                    .post(self.url(path))
                    .json(request)
                    .timeout(mutation_timeout_for_path(path)),
            )
            .send()
            .map_err(ClientError::Request)?;
        Self::decode(response, "POST", path)
    }

    /// Perform an authenticated PUT and decode its JSON response.
    ///
    /// # Errors
    /// Returns [`ClientError`] on transport, non-success status, or decode failure.
    pub fn put<Request, Response>(
        &self,
        path: &str,
        request: &Request,
    ) -> Result<Response, ClientError>
    where
        Request: Serialize + ?Sized,
        Response: DeserializeOwned,
    {
        let response = self
            .request(
                self.http
                    .put(self.url(path))
                    .json(request)
                    .timeout(mutation_timeout_for_path(path)),
            )
            .send()
            .map_err(ClientError::Request)?;
        Self::decode(response, "PUT", path)
    }

    /// Perform an authenticated DELETE and decode its JSON response.
    ///
    /// Every daemon DELETE route takes its identifier from the path (or an
    /// optional query) rather than a JSON body, so this carries no request
    /// parameter -- unlike `post`/`put`, which always send one.
    ///
    /// # Errors
    /// Returns [`ClientError`] on transport, non-success status, or decode failure.
    pub fn delete<Response>(&self, path: &str) -> Result<Response, ClientError>
    where
        Response: DeserializeOwned,
    {
        let response = self
            .request(self.http.delete(self.url(path)))
            .send()
            .map_err(ClientError::Request)?;
        Self::decode(response, "DELETE", path)
    }

    fn from_manifest(manifest: &DaemonManifest) -> Result<Self, ClientError> {
        let path = if manifest.token_path.trim().is_empty() {
            state::auth_token_path()
        } else {
            manifest.token_path.trim().into()
        };
        let token = fs::read_to_string(&path)
            .map_err(|source| ClientError::ReadToken {
                path: path.clone(),
                source,
            })?
            .trim()
            .to_string();
        if token.is_empty() {
            return Err(ClientError::EmptyToken { path });
        }
        let http = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(ClientError::Build)?;
        Ok(Self {
            endpoint: manifest.endpoint.trim_end_matches('/').to_string(),
            token,
            http,
        })
    }

    fn health_is_ready(&self) -> bool {
        self.request(self.http.get(self.url("/v1/health")))
            .timeout(HEALTH_TIMEOUT)
            .send()
            .map_err(ClientError::Request)
            .is_ok_and(|response| response.status().is_success())
    }

    fn authenticated_api_is_ready(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut path = "/v1/ready";
        loop {
            match self.readiness_probe(path) {
                Readiness::Ready => return true,
                Readiness::Missing if path == "/v1/ready" => {
                    path = "/v1/sessions";
                    continue;
                }
                Readiness::Missing | Readiness::NotReady => {}
            }
            if Instant::now() >= deadline {
                return false;
            }
            thread::sleep(API_READY_INTERVAL);
        }
    }

    fn readiness_probe(&self, path: &str) -> Readiness {
        let response = self
            .request(self.http.get(self.url(path)))
            .timeout(HEALTH_TIMEOUT)
            .send()
            .map_err(ClientError::Request);
        match response {
            Ok(response) if response.status().is_success() => Readiness::Ready,
            Ok(response) if response.status() == StatusCode::NOT_FOUND => Readiness::Missing,
            Ok(_) | Err(_) => Readiness::NotReady,
        }
    }

    fn request(&self, request: RequestBuilder) -> RequestBuilder {
        request.bearer_auth(&self.token)
    }

    fn decode<T>(response: Response, method: &'static str, path: &str) -> Result<T, ClientError>
    where
        T: DeserializeOwned,
    {
        let status = response.status();
        let body = response.text().map_err(ClientError::Request)?;
        if !status.is_success() {
            return Err(ClientError::Response {
                method,
                path: path.to_string(),
                status: status.as_u16(),
                body,
            });
        }
        // A 204 (or any success with no body, e.g. `DELETE /v1/sessions/{id}`)
        // sends an empty string, which is not valid JSON on its own -- treat
        // it as `null` so `T = ()` / `Option<_>` still decode.
        let body = if body.trim().is_empty() {
            "null"
        } else {
            &body
        };
        serde_json::from_str(body).map_err(|source| ClientError::Decode {
            method,
            path: path.to_string(),
            source,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.endpoint, path)
    }

    /// Build a client against an arbitrary endpoint, bypassing daemon
    /// discovery and token loading. `test-support` exists so other crates in
    /// the workspace can drive this client against a mock HTTP server in
    /// their own tests, the same way this crate's own tests do.
    #[cfg(any(test, feature = "test-support"))]
    #[must_use]
    pub fn test_client(endpoint: String, token: &str) -> Self {
        Self {
            endpoint,
            token: token.to_string(),
            http: Client::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Readiness {
    Ready,
    Missing,
    NotReady,
}

/// Mirrors the root facade's `daemon::client::http::mutation_timeout_for_path`.
/// A handful of task-board and policy mutations are known long-running
/// operations; without this, every `post`/`put` inherited the client's flat
/// 5s default and would fail against a real daemon on anything slower than
/// that, a regression the facade's callers never hit because it already
/// special-cased these paths.
fn mutation_timeout_for_path(path: &str) -> Duration {
    if path == "/v1/sessions" {
        SESSION_START_TIMEOUT
    } else if matches!(
        path,
        "/v1/task-board/sync"
            | "/v1/task-board/dispatch"
            | "/v1/task-board/dispatch/deliver"
            | "/v1/task-board/evaluate"
            | "/v1/task-board/orchestrator/run-once"
            | "/v1/policies/dump"
            | "/v1/policies/import"
    ) {
        TASK_BOARD_OPERATION_TIMEOUT
    } else {
        REQUEST_TIMEOUT
    }
}

#[cfg(test)]
mod tests;
