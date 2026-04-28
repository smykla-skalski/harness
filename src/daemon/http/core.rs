use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use axum::extract::Query;

use crate::agents::acp::probe::probe_acp_agents_cached;
use crate::daemon::bridge::reconfigure_bridge;
use crate::daemon::protocol::{
    HostBridgeReconfigureRequest, ReadinessResponse, RuntimeSessionResolutionResponse,
    SetLogLevelRequest, http_paths,
};
use crate::daemon::service;
use crate::daemon::websocket::ws_upgrade_handler;

use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};
use super::stream::stream_global;
use super::{DaemonHttpState, require_async_db};

pub(super) fn core_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(http_paths::HEALTH, get(get_health))
        .route(http_paths::READY, get(get_ready))
        .route(http_paths::DIAGNOSTICS, get(get_diagnostics))
        .route(http_paths::DAEMON_STOP, post(post_stop_daemon))
        .route(
            http_paths::BRIDGE_RECONFIGURE,
            post(post_bridge_reconfigure),
        )
        .route(
            http_paths::DAEMON_LOG_LEVEL,
            get(get_log_level).put(put_log_level),
        )
        .route(http_paths::PROJECTS, get(get_projects))
        .route(
            http_paths::RUNTIME_SESSION_RESOLVE,
            get(get_runtime_session_resolution),
        )
        .route(http_paths::RUNTIMES_PROBE, get(get_runtimes_probe))
        .route(http_paths::WS, get(ws_upgrade_handler))
        .route(http_paths::STREAM, get(stream_global))
}

/// Query parameters for `GET /v1/runtime-sessions/resolve`.
#[derive(Debug, serde::Deserialize)]
pub(crate) struct RuntimeSessionResolutionQuery {
    pub runtime_name: String,
    pub runtime_session_id: String,
}

pub(super) async fn get_health(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "health") {
        Ok(async_db) => service::health_response_async(&state.manifest, Some(async_db)).await,
        Err(error) => Err(error),
    };
    timed_json("GET", http_paths::HEALTH, &request_id, start, result)
}

pub(super) async fn get_ready(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = require_async_db(&state, "ready").map(|_| ReadinessResponse {
        ready: true,
        daemon_epoch: state.daemon_epoch.clone(),
    });
    timed_json("GET", http_paths::READY, &request_id, start, result)
}

pub(super) async fn get_runtime_session_resolution(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(query): Query<RuntimeSessionResolutionQuery>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "runtime session resolution") {
        Ok(async_db) => service::resolve_runtime_session_agent_async(
            &query.runtime_name,
            &query.runtime_session_id,
            Some(async_db),
        )
        .await
        .map(|resolved| RuntimeSessionResolutionResponse { resolved }),
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::RUNTIME_SESSION_RESOLVE,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_diagnostics(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "diagnostics") {
        Ok(async_db) => service::diagnostics_report_async(Some(async_db)).await,
        Err(error) => Err(error),
    };
    timed_json("GET", http_paths::DIAGNOSTICS, &request_id, start, result)
}

pub(super) async fn get_runtimes_probe(
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
        http_paths::RUNTIMES_PROBE,
        &request_id,
        start,
        Ok(probe_acp_agents_cached()),
    )
}

async fn post_stop_daemon(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    state.acp_agent_manager.shutdown_all();
    timed_json(
        "POST",
        http_paths::DAEMON_STOP,
        &request_id,
        start,
        service::request_shutdown(),
    )
}

async fn post_bridge_reconfigure(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<HostBridgeReconfigureRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        http_paths::BRIDGE_RECONFIGURE,
        &request_id,
        start,
        reconfigure_bridge(&request.enable, &request.disable, request.force),
    )
}

async fn get_log_level(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        http_paths::DAEMON_LOG_LEVEL,
        &request_id,
        start,
        service::get_log_level(),
    )
}

async fn put_log_level(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SetLogLevelRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "PUT",
        http_paths::DAEMON_LOG_LEVEL,
        &request_id,
        start,
        service::set_log_level(&request, &state.sender),
    )
}

pub(super) async fn get_projects(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "projects") {
        Ok(async_db) => service::list_projects_async(Some(async_db)).await,
        Err(error) => Err(error),
    };
    timed_json("GET", http_paths::PROJECTS, &request_id, start, result)
}
