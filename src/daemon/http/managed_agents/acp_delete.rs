use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::{ManagedAgentSnapshot, http_paths};
use crate::errors::{CliError, CliErrorKind};

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};
use super::ensure_acp_agent;

#[derive(Debug, Deserialize)]
pub(super) struct DeleteAcpAgentQuery {
    pub(super) require_session_id: Option<String>,
}

pub(super) async fn delete_acp_agent(
    Path(agent_id): Path<String>,
    Query(query): Query<DeleteAcpAgentQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = (|| -> Result<ManagedAgentSnapshot, CliError> {
        ensure_acp_agent(&state, &agent_id)?;
        if let Some(required) = &query.require_session_id {
            let snapshot = state.acp_agent_manager.get(&agent_id)?;
            if &snapshot.session_id != required {
                return Err(CliErrorKind::session_scope_denied(format!(
                    "agent '{agent_id}' belongs to a different session"
                ))
                .into());
            }
        }
        state
            .acp_agent_manager
            .stop(&agent_id)
            .map(ManagedAgentSnapshot::Acp)
    })();
    timed_json(
        "DELETE",
        http_paths::MANAGED_AGENT_DELETE,
        &request_id,
        start,
        result,
    )
}
