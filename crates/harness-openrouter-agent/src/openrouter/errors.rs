//! Error type for the `OpenRouter` HTTP client.
//!
//! HTTP status codes are mapped to dedicated variants so callers can react to
//! rate limits and credit exhaustion without re-parsing the body. The mapping
//! follows the categories documented at <https://openrouter.ai/docs/errors>.

use std::time::Duration;

use harness_protocol::managed_agents::runtime_failures::{
    AgentTurnFailure, AgentTurnFailureCategory, AgentTurnFailureStage,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum OpenRouterError {
    #[error("failed to serialize chat request: {0}")]
    SerializeRequest(#[source] serde_json::Error),
    #[error("HTTP request to OpenRouter failed: {0}")]
    Transport(#[source] reqwest::Error),
    #[error("failed to read OpenRouter response body: {0}")]
    ReadBody(#[source] reqwest::Error),
    #[error("failed to parse OpenRouter response: {0}")]
    Deserialize(#[source] serde_json::Error),
    #[error("OpenRouter stream ended before [DONE]")]
    IncompleteStream,
    /// HTTP 401 / 402 from `OpenRouter` — bad or unauthorized key.
    #[error("OpenRouter authentication failed: {body}")]
    AuthenticationFailed { body: String },
    /// HTTP 403 — moderation or policy block on the prompt.
    #[error("OpenRouter blocked the request (moderation): {body}")]
    Moderation { body: String },
    /// HTTP 429 — rate limit hit; `retry_after` is parsed from the
    /// `X-RateLimit-Reset` or `Retry-After` header when present.
    #[error("OpenRouter rate limit exceeded")]
    RateLimited { retry_after: Option<Duration> },
    /// HTTP 502 / 503 — upstream provider overloaded.
    #[error("OpenRouter upstream overloaded ({status})")]
    Overloaded { status: u16 },
    /// Any other non-2xx response.
    #[error("OpenRouter returned HTTP {status}: {body}")]
    ApiError { status: u16, body: String },
}

impl From<reqwest::Error> for OpenRouterError {
    fn from(error: reqwest::Error) -> Self {
        OpenRouterError::Transport(error)
    }
}

impl OpenRouterError {
    #[must_use]
    pub fn turn_failure(&self) -> AgentTurnFailure {
        let (category, detail) = match self {
            Self::SerializeRequest(_) => (
                AgentTurnFailureCategory::Unknown,
                "OpenRouter request serialization failed".to_owned(),
            ),
            Self::Transport(_) | Self::ReadBody(_) => (
                AgentTurnFailureCategory::Transport,
                "OpenRouter transport failed".to_owned(),
            ),
            Self::Deserialize(_) => (
                AgentTurnFailureCategory::Transport,
                "OpenRouter response stream was malformed".to_owned(),
            ),
            Self::IncompleteStream => (
                AgentTurnFailureCategory::Transport,
                "OpenRouter response stream ended before [DONE]".to_owned(),
            ),
            Self::AuthenticationFailed { .. } => (
                AgentTurnFailureCategory::Authentication,
                "OpenRouter rejected its credential".to_owned(),
            ),
            Self::Moderation { .. } => (
                AgentTurnFailureCategory::ProviderRejected,
                "OpenRouter rejected the prompt".to_owned(),
            ),
            Self::RateLimited { retry_after } => (
                AgentTurnFailureCategory::RateLimited,
                retry_detail(*retry_after),
            ),
            Self::Overloaded { status } => (
                AgentTurnFailureCategory::Transport,
                format!("OpenRouter provider unavailable with HTTP {status}"),
            ),
            Self::ApiError { status, body } => (
                api_failure_category(*status, body),
                format!("OpenRouter rejected the request with HTTP {status}"),
            ),
        };
        AgentTurnFailure::new(category, AgentTurnFailureStage::Execution, detail)
    }
}

fn api_failure_category(status: u16, body: &str) -> AgentTurnFailureCategory {
    let category = AgentTurnFailureCategory::from_message(body);
    if category != AgentTurnFailureCategory::Unknown {
        category
    } else if status >= 500 {
        AgentTurnFailureCategory::Transport
    } else {
        AgentTurnFailureCategory::ProviderRejected
    }
}

fn retry_detail(retry_after: Option<Duration>) -> String {
    retry_after.map_or_else(
        || "OpenRouter rate limit reached".to_owned(),
        |delay| {
            format!(
                "OpenRouter rate limit reached; retry after {} seconds",
                delay.as_secs()
            )
        },
    )
}

/// Classify a non-2xx HTTP response into the matching error variant.
#[must_use]
pub fn classify_status(
    status: u16,
    retry_after: Option<Duration>,
    body: String,
) -> OpenRouterError {
    match status {
        401 | 402 => OpenRouterError::AuthenticationFailed { body },
        403 => OpenRouterError::Moderation { body },
        429 => OpenRouterError::RateLimited { retry_after },
        502 | 503 => OpenRouterError::Overloaded { status },
        _ => OpenRouterError::ApiError { status, body },
    }
}

/// Parse a `Retry-After` (seconds) or `X-RateLimit-Reset` (seconds) header
/// value into a `Duration`. Returns `None` if the value is unusable.
#[must_use]
pub fn parse_retry_after(header_value: &str) -> Option<Duration> {
    header_value
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|seconds| *seconds < 60 * 60 * 24 * 30)
        .map(Duration::from_secs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_rate_limit_status() {
        let error = classify_status(429, Some(Duration::from_secs(7)), "rate limited".to_owned());
        assert!(matches!(
            error,
            OpenRouterError::RateLimited { retry_after: Some(d) } if d == Duration::from_secs(7)
        ));
    }

    #[test]
    fn maps_auth_status() {
        let error = classify_status(401, None, "bad key".to_owned());
        assert!(matches!(
            error,
            OpenRouterError::AuthenticationFailed { .. }
        ));
    }

    #[test]
    fn maps_overload_status() {
        let error = classify_status(503, None, String::new());
        assert!(matches!(error, OpenRouterError::Overloaded { status: 503 }));
    }

    #[test]
    fn parse_retry_after_accepts_seconds() {
        assert_eq!(parse_retry_after("5"), Some(Duration::from_secs(5)));
    }

    #[test]
    fn parse_retry_after_rejects_garbage() {
        assert_eq!(parse_retry_after("soon"), None);
    }

    #[test]
    fn maps_provider_errors_to_shared_recovery_categories() {
        use harness_protocol::managed_agents::runtime_failures::AgentTurnFailureCategory;

        let cases = [
            (
                OpenRouterError::AuthenticationFailed {
                    body: "secret response".into(),
                },
                AgentTurnFailureCategory::Authentication,
                false,
            ),
            (
                OpenRouterError::RateLimited { retry_after: None },
                AgentTurnFailureCategory::RateLimited,
                true,
            ),
            (
                OpenRouterError::Overloaded { status: 503 },
                AgentTurnFailureCategory::Transport,
                false,
            ),
            (
                OpenRouterError::IncompleteStream,
                AgentTurnFailureCategory::Transport,
                false,
            ),
            (
                OpenRouterError::ApiError {
                    status: 400,
                    body: "rejected".into(),
                },
                AgentTurnFailureCategory::ProviderRejected,
                false,
            ),
        ];

        for (error, category, retry_safe) in cases {
            let failure = error.turn_failure();
            assert_eq!(failure.category, category);
            assert_eq!(failure.automatic_retry_safe, retry_safe);
            assert!(!failure.detail.contains("secret response"));
        }
    }
}
