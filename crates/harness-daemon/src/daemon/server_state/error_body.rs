use serde::{Deserialize, Serialize};

// Lives here rather than `crate::daemon::http::openapi` so
// `task_board_remote_transport`'s `#[utoipa::path]` response annotations can
// name it without reaching into `http`; `http::openapi` re-exports it so its
// own callers keep the same import path. Doc comment left untouched below -
// `utoipa::ToSchema` renders it into the public OpenAPI description.
/// Error envelope returned by daemon handlers on failure.
///
/// Mirrors the dominant shape produced by `error_status_and_body`
/// (`{"error": {"code", "message", "details"}}`). A few endpoints emit
/// alternate ad-hoc error shapes for specific conditions; those are noted in
/// the relevant operation descriptions.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonErrorBody {
    pub error: DaemonErrorDetail,
}

/// Structured error detail carried by [`DaemonErrorBody`].
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DaemonErrorDetail {
    /// Stable machine-readable error code (for example `SESSION_SCOPE_DENIED`).
    pub code: String,
    /// Human-readable error message.
    pub message: String,
    /// Optional additional context lines.
    #[serde(default)]
    pub details: Vec<String>,
}
