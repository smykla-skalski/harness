use std::time::Instant;

use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::http_paths;
#[cfg(feature = "openapi")]
use crate::daemon::protocol::CodexAgentInspectResponse;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
#[cfg(feature = "openapi")]
use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_json};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CodexInspectQuery {
    session_id: Option<String>,
}

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/managed-agents/codex/inspect",
    tag = "managed-agents",
    params(
        ("session_id" = Option<String>, Query, description = "Restrict the inspection to one session"),
    ),
    responses(
        (status = 200, description = "Codex managed-agent inspection", body = CodexAgentInspectResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn get_codex_inspect(
    Query(query): Query<CodexInspectQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.codex_controller.inspect(query.session_id.as_deref());
    timed_json(
        "GET",
        http_paths::MANAGED_AGENTS_CODEX_INSPECT,
        &request_id,
        start,
        result,
    )
}
