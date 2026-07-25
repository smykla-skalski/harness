use std::time::Instant;

use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::http_paths;
use crate::daemon::protocol::CodexTranscriptResponse;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_json};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CodexTranscriptQuery {
    session_id: Option<String>,
}

#[utoipa::path(
    get,
    path = "/v1/managed-agents/codex/transcript",
    tag = "managed-agents",
    description = "Read the recorded Codex agent transcript entries for a session. The session_id query parameter is required; omitting it returns a 400 usage error",
    params(
        ("session_id" = String, Query, description = "Session whose Codex transcript to read (required)"),
    ),
    responses(
        (status = 200, description = "Codex agent transcript entries", body = CodexTranscriptResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_codex_transcript(
    Query(query): Query<CodexTranscriptQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }

    let result = query.session_id.ok_or_else(|| {
        CliError::new(CliErrorKind::usage_error(
            "session_id is required for Codex transcript reads",
        ))
    });
    let result = result.and_then(|session_id| state.codex_controller.transcript(&session_id));
    timed_json(
        "GET",
        http_paths::MANAGED_AGENTS_CODEX_TRANSCRIPT,
        &request_id,
        start,
        result,
    )
}
