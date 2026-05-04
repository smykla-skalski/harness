use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::protocol::http_paths;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};
use super::{managed_agent_list_response, managed_agent_snapshot};

pub(crate) async fn get_managed_agents(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = managed_agent_list_response(&state, &session_id);
    timed_json(
        "GET",
        http_paths::SESSION_MANAGED_AGENTS,
        &request_id,
        start,
        result,
    )
}

pub(crate) async fn get_managed_agent(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        http_paths::MANAGED_AGENT_DETAIL,
        &request_id,
        start,
        managed_agent_snapshot(&state, &agent_id),
    )
}
