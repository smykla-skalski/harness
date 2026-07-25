//! Panel failures, and how a request-time failure reaches the browser.

use std::io::Error as IoError;
use std::path::Path;

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Serialize;
use sqlx::migrate::MigrateError;

/// A failure that stops the panel from starting or from serving a request.
#[derive(Debug, thiserror::Error)]
pub enum PanelError {
    #[error("invalid panel configuration: {0}")]
    Config(String),

    #[error("{action} {path}: {source}")]
    Io {
        action: &'static str,
        path: String,
        #[source]
        source: IoError,
    },

    #[error("panel storage: {0}")]
    Storage(#[from] sqlx::Error),

    #[error("panel storage migration: {0}")]
    Migration(#[from] MigrateError),

    #[error("github sign-in: {0}")]
    GitHub(String),

    #[error("daemon: {0}")]
    Daemon(String),

    /// Carries no path, because this failure is about the host's ability to
    /// start threads and has nothing to do with any file the panel names.
    #[error("starting the panel async runtime: {0}")]
    Runtime(#[source] IoError),

    #[error("serving the panel on {address}: {source}")]
    Bind {
        address: String,
        #[source]
        source: IoError,
    },
}

impl PanelError {
    pub fn config(message: impl Into<String>) -> Self {
        Self::Config(message.into())
    }

    pub fn github(message: impl Into<String>) -> Self {
        Self::GitHub(message.into())
    }

    pub fn daemon(message: impl Into<String>) -> Self {
        Self::Daemon(message.into())
    }

    #[must_use]
    pub fn io(action: &'static str, path: &Path, source: IoError) -> Self {
        Self::Io {
            action,
            path: path.display().to_string(),
            source,
        }
    }
}

/// A failure the browser is allowed to see.
///
/// Every variant carries a stable machine-readable code so the single-page app
/// can distinguish authentication and sign-in failures from an internal
/// failure without matching on prose. Storage and upstream failures
/// deliberately share the fixed `internal` code and message: the detail
/// belongs in the log, not in a page anyone can load.
#[derive(Debug)]
pub enum ApiError {
    Unauthenticated,
    Forbidden(&'static str),
    RateLimited(&'static str),
    NotFound(&'static str),
    Unavailable(&'static str),
    BadRequest(String),
    SignInFailed(String),
    Internal(PanelError),
}

impl ApiError {
    fn parts(&self) -> (StatusCode, &'static str, String) {
        match self {
            Self::Unauthenticated => (
                StatusCode::UNAUTHORIZED,
                "unauthenticated",
                "sign in to use the panel".to_owned(),
            ),
            Self::Forbidden(message) => (StatusCode::FORBIDDEN, "forbidden", (*message).to_owned()),
            Self::RateLimited(message) => (
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limited",
                (*message).to_owned(),
            ),
            Self::NotFound(message) => (StatusCode::NOT_FOUND, "not_found", (*message).to_owned()),
            Self::Unavailable(message) => (
                StatusCode::SERVICE_UNAVAILABLE,
                "unavailable",
                (*message).to_owned(),
            ),
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, "bad_request", message.clone()),
            Self::SignInFailed(message) => (StatusCode::BAD_REQUEST, "sign_in", message.clone()),
            Self::Internal(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "the panel could not complete this request".to_owned(),
            ),
        }
    }
}

impl From<PanelError> for ApiError {
    fn from(error: PanelError) -> Self {
        Self::Internal(error)
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(error: sqlx::Error) -> Self {
        Self::Internal(PanelError::Storage(error))
    }
}

#[derive(Debug, Serialize)]
struct ApiErrorEnvelope {
    error: ApiErrorBody,
}

#[derive(Debug, Serialize)]
struct ApiErrorBody {
    code: &'static str,
    message: String,
}

impl ApiErrorEnvelope {
    fn new(code: &'static str, message: String) -> Self {
        Self {
            error: ApiErrorBody { code, message },
        }
    }
}

impl IntoResponse for ApiError {
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn into_response(self) -> Response {
        // The caller sees a fixed sentence for an internal failure, so this is
        // the only place its cause is recorded at all.
        if let Self::Internal(error) = &self {
            tracing::error!(error = %error, "panel request failed");
        }
        let (status, code, message) = self.parts();
        (status, Json(ApiErrorEnvelope::new(code, message))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::{ApiError, PanelError};
    use axum::http::StatusCode;

    #[test]
    fn each_variant_answers_with_its_own_status_and_code() {
        for (error, status, code) in [
            (
                ApiError::Unauthenticated,
                StatusCode::UNAUTHORIZED,
                "unauthenticated",
            ),
            (
                ApiError::Forbidden("owner only"),
                StatusCode::FORBIDDEN,
                "forbidden",
            ),
            (
                ApiError::RateLimited("try later"),
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limited",
            ),
            (
                ApiError::BadRequest("missing code".to_owned()),
                StatusCode::BAD_REQUEST,
                "bad_request",
            ),
            (
                ApiError::SignInFailed("state expired".to_owned()),
                StatusCode::BAD_REQUEST,
                "sign_in",
            ),
        ] {
            let (actual_status, actual_code, _) = error.parts();
            assert_eq!(actual_status, status);
            assert_eq!(actual_code, code);
        }
    }

    /// Storage detail can name paths and SQL; the browser gets a fixed sentence
    /// and the operator gets the rest from the log.
    #[test]
    fn an_internal_failure_never_repeats_its_cause_to_the_caller() {
        let error = ApiError::Internal(PanelError::config("secret file /etc/panel/secret is 0644"));

        let (status, code, message) = error.parts();

        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(code, "internal");
        assert!(!message.contains("/etc/panel/secret"), "{message}");
    }
}
