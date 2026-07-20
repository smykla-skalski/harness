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

use crate::daemon::protocol::http_paths;
use crate::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};
use super::{ensure_acp_agent, ensure_acp_enabled, run_acp_agent_blocking};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ListAcpSessionsQuery {
    pub(super) cwd: Option<String>,
    pub(super) cursor: Option<String>,
}

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
                manager
                    .list_agent_sessions(&list_agent_id, cwd, cursor)
                    .and_then(|page| {
                        serde_json::to_value(page).map_err(|error| {
                            crate::errors::CliErrorKind::workflow_io(format!(
                                "serialize ACP session list: {error}"
                            ))
                            .into()
                        })
                    })
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
