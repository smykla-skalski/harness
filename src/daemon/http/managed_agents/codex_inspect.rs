use std::time::Instant;

use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::http_paths;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CodexInspectQuery {
    session_id: Option<String>,
}

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
