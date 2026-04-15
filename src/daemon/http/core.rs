use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::daemon::bridge::reconfigure_bridge;
use crate::daemon::protocol::{HostBridgeReconfigureRequest, SetLogLevelRequest};
use crate::daemon::read_cache::run_canonical_db_read;
use crate::daemon::service;
use crate::daemon::websocket::ws_upgrade_handler;
use crate::errors::CliError;
use crate::session::persona;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};
use super::stream::stream_global;

pub(super) fn core_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route("/v1/health", get(get_health))
        .route("/v1/diagnostics", get(get_diagnostics))
        .route("/v1/daemon/stop", post(post_stop_daemon))
        .route("/v1/bridge/reconfigure", post(post_bridge_reconfigure))
        .route(
            "/v1/daemon/log-level",
            get(get_log_level).put(put_log_level),
        )
        .route("/v1/personas", get(get_personas))
        .route("/v1/projects", get(get_projects))
        .route("/v1/ws", get(ws_upgrade_handler))
        .route("/v1/stream", get(stream_global))
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
    let result = if let Some(async_db) = state.async_db.get() {
        service::health_response_async(&state.manifest, Some(async_db.as_ref())).await
    } else {
        let manifest = state.manifest.clone();
        run_canonical_db_read(&state.db, state.db_path.clone(), "health", {
            move |db| service::health_response(&manifest, Some(db))
        })
        .await
    };
    timed_json("GET", "/v1/health", &request_id, start, result)
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
    let result = if let Some(async_db) = state.async_db.get() {
        service::diagnostics_report_async(Some(async_db.as_ref())).await
    } else {
        run_canonical_db_read(&state.db, state.db_path.clone(), "diagnostics", |db| {
            service::diagnostics_report(Some(db))
        })
        .await
    };
    timed_json("GET", "/v1/diagnostics", &request_id, start, result)
}

async fn get_personas(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        "/v1/personas",
        &request_id,
        start,
        Ok::<_, CliError>(persona::all()),
    )
}

async fn post_stop_daemon(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/daemon/stop",
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
        "/v1/bridge/reconfigure",
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
        "/v1/daemon/log-level",
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
        "/v1/daemon/log-level",
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
    let result = if let Some(async_db) = state.async_db.get() {
        service::list_projects_async(Some(async_db.as_ref())).await
    } else {
        run_canonical_db_read(&state.db, state.db_path.clone(), "projects", |db| {
            service::list_projects(Some(db))
        })
        .await
    };
    timed_json("GET", "/v1/projects", &request_id, start, result)
}
