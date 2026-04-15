use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::daemon::agent_tui::{AgentTuiInputRequest, AgentTuiResizeRequest, AgentTuiStartRequest};
use crate::daemon::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, RoleChangeRequest, SessionDetail,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::DaemonHttpState;
use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};

pub(super) fn agent_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            "/v1/sessions/{session_id}/agents/{agent_id}/role",
            post(post_role_change),
        )
        .route(
            "/v1/sessions/{session_id}/agents/{agent_id}/remove",
            post(post_remove_agent),
        )
        .route(
            "/v1/sessions/{session_id}/leader",
            post(post_transfer_leader),
        )
}

pub(super) fn agent_tui_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            "/v1/sessions/{session_id}/agent-tuis",
            get(get_agent_tuis).post(post_agent_tui_start),
        )
        .route("/v1/agent-tuis/{tui_id}", get(get_agent_tui))
        .route("/v1/agent-tuis/{tui_id}/input", post(post_agent_tui_input))
        .route(
            "/v1/agent-tuis/{tui_id}/resize",
            post(post_agent_tui_resize),
        )
        .route("/v1/agent-tuis/{tui_id}/stop", post(post_agent_tui_stop))
        .route("/v1/agent-tuis/{tui_id}/ready", post(post_agent_tui_ready))
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
        "/v1/sessions/{id}/agents/{id}/role",
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
        "/v1/sessions/{id}/agents/{id}/remove",
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
        "/v1/sessions/{id}/leader",
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

pub(super) async fn get_agent_tuis(
    Path(session_id): Path<String>,
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
        "/v1/sessions/{id}/agent-tuis",
        &request_id,
        start,
        state.agent_tui_manager.list(&session_id),
    )
}

async fn post_agent_tui_start(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.agent_tui_manager.start(&session_id, &request);
    if result.is_ok() {
        if let Some(async_db) = state.async_db.get() {
            service::broadcast_session_snapshot_async(
                &state.sender,
                &session_id,
                Some(async_db.as_ref()),
            )
            .await;
        } else {
            let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
            let db_ref = db_guard.as_deref();
            service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
        }
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/agent-tuis",
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_agent_tui(
    Path(tui_id): Path<String>,
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
        "/v1/agent-tuis/{id}",
        &request_id,
        start,
        state.agent_tui_manager.get(&tui_id),
    )
}

async fn post_agent_tui_input(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiInputRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/agent-tuis/{id}/input",
        &request_id,
        start,
        state.agent_tui_manager.input(&tui_id, &request),
    )
}

async fn post_agent_tui_resize(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiResizeRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/agent-tuis/{id}/resize",
        &request_id,
        start,
        state.agent_tui_manager.resize(&tui_id, &request),
    )
}

async fn post_agent_tui_stop(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.agent_tui_manager.stop(&tui_id);
    if let Ok(snapshot) = &result {
        if let Some(async_db) = state.async_db.get() {
            service::broadcast_session_snapshot_async(
                &state.sender,
                &snapshot.session_id,
                Some(async_db.as_ref()),
            )
            .await;
        } else {
            let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
            let db_ref = db_guard.as_deref();
            service::broadcast_session_snapshot(&state.sender, &snapshot.session_id, db_ref);
        }
    }
    timed_json(
        "POST",
        "/v1/agent-tuis/{id}/stop",
        &request_id,
        start,
        result,
    )
}

async fn post_agent_tui_ready(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/agent-tuis/{id}/ready",
        &request_id,
        start,
        state.agent_tui_manager.signal_ready(&tui_id),
    )
}
