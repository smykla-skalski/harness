use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::agent_acp::AcpAgentStartRequest;
use crate::daemon::protocol::{ManagedAgentSnapshot, http_paths};

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};

pub(super) async fn post_acp_agent_start(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AcpAgentStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state
        .acp_agent_manager
        .start(&session_id, &request)
        .map(ManagedAgentSnapshot::Acp);
    timed_json(
        "POST",
        http_paths::SESSION_MANAGED_AGENTS_ACP,
        &request_id,
        start,
        result,
    )
}
