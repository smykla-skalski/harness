//! Routes over the agent's own session store: list, close, and delete.
//!
//! The ids these routes accept and return belong to the agent, not to harness.
//! An agent may report sessions harness never started and may have forgotten
//! sessions harness still tracks, so nothing here is reconciled against the
//! harness session index.

use std::path::PathBuf;
use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::agent_acp::AcpSessionListPage;
use crate::daemon::protocol::http_paths;
use crate::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::openapi::{DaemonErrorBody, OkResponse};
use super::super::response::{extract_request_id, timed_json};
use super::{ensure_acp_agent, ensure_acp_enabled, run_acp_agent_blocking};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ListAcpSessionsQuery {
    pub(super) cwd: Option<String>,
    pub(super) cursor: Option<String>,
}

#[utoipa::path(
    get,
    path = "/v1/managed-agents/{managed_agent_id}/sessions",
    tag = "managed-agents",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
        ("cwd" = Option<String>, Query, description = "Working directory the agent scopes its session list to"),
        ("cursor" = Option<String>, Query, description = "Opaque pagination cursor from a previous page"),
    ),
    responses(
        (status = 200, description = "One page of agent-reported sessions", body = AcpSessionListPage),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_acp_sessions(
    Path(agent_id): Path<String>,
    Query(query): Query<ListAcpSessionsQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match acp_agent_gate(&state, &agent_id) {
        Ok(()) => {
            let list_agent_id = agent_id.clone();
            let cwd = query.cwd.map(PathBuf::from);
            let cursor = query.cursor;
            run_acp_agent_blocking(&state, "session-list", move |manager| {
                manager.list_agent_sessions(&list_agent_id, cwd, cursor)
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::MANAGED_AGENT_ACP_SESSIONS,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    delete,
    path = "/v1/managed-agents/{managed_agent_id}/sessions/{agent_session_id}",
    tag = "managed-agents",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
        ("agent_session_id" = String, Path, description = "Agent-owned session identifier"),
    ),
    responses(
        (status = 200, description = "Agent session deleted", body = OkResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn delete_acp_session(
    Path((agent_id, agent_session_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match acp_agent_gate(&state, &agent_id) {
        Ok(()) => {
            run_acp_agent_blocking(&state, "session-delete", move |manager| {
                manager
                    .delete_agent_session(&agent_id, &agent_session_id)
                    .map(|()| serde_json::json!({ "ok": true }))
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "DELETE",
        http_paths::MANAGED_AGENT_ACP_SESSION_DELETE,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/sessions/{agent_session_id}/close",
    tag = "managed-agents",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
        ("agent_session_id" = String, Path, description = "Agent-owned session identifier"),
    ),
    responses(
        (status = 200, description = "Agent session closed", body = OkResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_acp_session_close(
    Path((agent_id, agent_session_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match acp_agent_gate(&state, &agent_id) {
        Ok(()) => {
            run_acp_agent_blocking(&state, "session-close", move |manager| {
                manager
                    .close_agent_session(&agent_id, &agent_session_id)
                    .map(|()| serde_json::json!({ "ok": true }))
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_ACP_SESSION_CLOSE,
        &request_id,
        start,
        result,
    )
}

fn acp_agent_gate(state: &DaemonHttpState, agent_id: &str) -> Result<(), CliError> {
    ensure_acp_enabled()?;
    ensure_acp_agent(state, agent_id)
}
