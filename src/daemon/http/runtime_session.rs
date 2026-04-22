use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::protocol::{
    AgentRuntimeSessionRegistrationRequest, AgentRuntimeSessionRegistrationResponse, http_paths,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};
use super::{DaemonHttpState, sessions::broadcast_observe_session};

async fn runtime_session_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &AgentRuntimeSessionRegistrationRequest,
) -> Result<AgentRuntimeSessionRegistrationResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let registered =
            service::register_agent_runtime_session_direct_async(session_id, request, async_db)
                .await?;
        return Ok(AgentRuntimeSessionRegistrationResponse { registered });
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let registered =
        service::register_agent_runtime_session_direct(session_id, request, db_guard.as_deref())?;
    Ok(AgentRuntimeSessionRegistrationResponse { registered })
}

pub(super) async fn post_runtime_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentRuntimeSessionRegistrationRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = runtime_session_response(&state, &session_id, &request).await;
    if result.as_ref().is_ok_and(|response| response.registered) {
        broadcast_observe_session(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_RUNTIME_SESSION,
        &request_id,
        start,
        result,
    )
}
