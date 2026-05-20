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
use super::{ensure_acp_enabled, run_acp_agent_blocking};

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
    let result = match ensure_acp_enabled().and_then(|()| {
        state
            .acp_agent_manager
            .ensure_session_accepts_acp_start(&session_id)
    }) {
        Ok(()) => {
            let lock_agent_id = request.agent.clone();
            let start_session_id = session_id.clone();
            let _guard = state
                .managed_agent_mutation_locks
                .lock(&session_id, &lock_agent_id)
                .await;
            run_acp_agent_blocking(&state, "start", move |manager| {
                manager
                    .start(&start_session_id, &request)
                    .map(ManagedAgentSnapshot::Acp)
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::SESSION_MANAGED_AGENTS_ACP,
        &request_id,
        start,
        result,
    )
}
