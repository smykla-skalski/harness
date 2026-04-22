use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;
use axum::{Json, Router};

use crate::daemon::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, RoleChangeRequest, SessionDetail, http_paths,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::DaemonHttpState;
use super::auth::authorize_control_request;
use super::response::{extract_request_id, timed_json};

pub(super) fn agent_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(http_paths::SESSION_AGENT_ROLE, post(post_role_change))
        .route(http_paths::SESSION_AGENT_REMOVE, post(post_remove_agent))
        .route(
            http_paths::SESSION_LEADER_TRANSFER,
            post(post_transfer_leader),
        )
}

pub(super) async fn post_role_change(
    Path((session_id, agent_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<RoleChangeRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = role_change_response(&state, &session_id, &agent_id, &request).await;
    if result.is_ok() {
        broadcast_agent_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_AGENT_ROLE,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_remove_agent(
    Path((session_id, agent_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<AgentRemoveRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = remove_agent_response(&state, &session_id, &agent_id, &request).await;
    if result.is_ok() {
        broadcast_agent_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_AGENT_REMOVE,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_transfer_leader(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<LeaderTransferRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = transfer_leader_response(&state, &session_id, &request).await;
    if result.is_ok() {
        broadcast_agent_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_LEADER_TRANSFER,
        &request_id,
        start,
        result,
    )
}

async fn role_change_response(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
    request: &RoleChangeRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::change_role_async(session_id, agent_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::change_role(session_id, agent_id, request, db_guard.as_deref())
}

async fn transfer_leader_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &LeaderTransferRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::transfer_leader_async(session_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::transfer_leader(session_id, request, db_guard.as_deref())
}

async fn remove_agent_response(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::remove_agent_async(session_id, agent_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::remove_agent(session_id, agent_id, request, db_guard.as_deref())
}

async fn broadcast_agent_snapshot(state: &DaemonHttpState, session_id: &str) {
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_session_snapshot_async(
            &state.sender,
            session_id,
            Some(async_db.as_ref()),
        )
        .await;
        return;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::broadcast_session_snapshot(&state.sender, session_id, db_guard.as_deref());
}
