use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use axum::extract::Query;

use crate::agents::acp::probe::probe_acp_agents_cached;
use crate::daemon::audit_events::{AuditEventDraft, record_audit_result};
use crate::daemon::bridge::reconfigure_bridge_async;
use crate::daemon::protocol::{
    DaemonTelemetryRequest, HostBridgeReconfigureRequest, ReadinessResponse,
    RuntimeSessionResolutionResponse, SetLogLevelRequest, http_paths,
};
use crate::daemon::remote_diagnostics::project_diagnostics_report;
use crate::daemon::remote_viewer::is_remote_viewer;
use crate::daemon::service;
use crate::daemon::websocket::{build_config_payload, ws_upgrade_handler};
use crate::errors::{CliError, CliErrorKind};

#[cfg(feature = "openapi")]
use super::openapi::DaemonErrorBody;
#[cfg(feature = "openapi")]
use crate::daemon::protocol::{
    DaemonControlResponse, DaemonTelemetryResponse, HealthResponse, LogLevelResponse,
    ProjectSummary,
};

use super::audit::get_audit_events;
use super::auth::{authenticated_remote_client, require_auth};
use super::response::{extract_request_id, timed_json};
use super::stream::stream_global;
use super::{DaemonHttpState, require_async_db};

pub(super) fn core_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(http_paths::HEALTH, get(get_health))
        .route(http_paths::READY, get(get_ready))
        .route(http_paths::DIAGNOSTICS, get(get_diagnostics))
        .route(http_paths::GITHUB_STATUS, get(get_github_status))
        .route(http_paths::AUDIT_EVENTS, get(get_audit_events))
        .route(http_paths::DAEMON_TELEMETRY, post(post_daemon_telemetry))
        .route(http_paths::CONFIG, get(get_config))
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
#[cfg_attr(feature = "openapi", derive(utoipa::IntoParams))]
#[cfg_attr(feature = "openapi", into_params(parameter_in = Query))]
#[derive(Debug, serde::Deserialize)]
pub(crate) struct RuntimeSessionResolutionQuery {
    pub runtime_name: String,
    pub runtime_session_id: String,
}

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/health",
    tag = "daemon",
    responses(
        (status = 200, description = "Daemon health snapshot", body = HealthResponse),
        (status = 401, description = "Missing or invalid daemon token", body = DaemonErrorBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/ready",
    tag = "daemon",
    responses(
        (status = 200, description = "Readiness probe", body = ReadinessResponse),
        (status = 401, description = "Missing or invalid daemon token", body = DaemonErrorBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/runtime-sessions/resolve",
    tag = "daemon",
    params(RuntimeSessionResolutionQuery),
    responses(
        (status = 200, description = "Runtime-session resolution outcome", body = RuntimeSessionResolutionResponse),
        (status = 401, description = "Missing or invalid daemon token", body = DaemonErrorBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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
    let remote_client = match authenticated_remote_client(&headers, &state) {
        Ok(client) => client,
        Err(response) => return *response,
    };
    let viewer = is_remote_viewer(remote_client.as_ref());
    let result = match require_async_db(&state, "diagnostics") {
        Ok(async_db) => service::diagnostics_report_async(Some(async_db))
            .await
            .map(|report| project_diagnostics_report(report, viewer)),
        Err(error) => Err(error),
    };
    timed_json("GET", http_paths::DIAGNOSTICS, &request_id, start, result)
}

pub(super) async fn get_github_status(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = Ok::<_, CliError>(service::github_api_status_async().await);
    timed_json("GET", http_paths::GITHUB_STATUS, &request_id, start, result)
}

pub(super) async fn get_config(
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
        http_paths::CONFIG,
        &request_id,
        start,
        Ok(build_config_payload()),
    )
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/daemon/stop",
    tag = "daemon",
    responses(
        (status = 200, description = "Daemon shutdown acknowledged", body = DaemonControlResponse),
        (status = 401, description = "Missing or invalid daemon token", body = DaemonErrorBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn post_stop_daemon(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match state.acp_agent_manager.shutdown_all_async().await {
        Ok(()) => service::request_shutdown(),
        Err(error) => Err(error),
    };
    timed_json("POST", http_paths::DAEMON_STOP, &request_id, start, result)
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/daemon/telemetry",
    tag = "daemon",
    request_body = DaemonTelemetryRequest,
    responses(
        (status = 200, description = "Telemetry recorded", body = DaemonTelemetryResponse),
        (status = 401, description = "Missing or invalid daemon token", body = DaemonErrorBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn post_daemon_telemetry(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<DaemonTelemetryRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = if let Some(db) = state.db.get() {
        match db.lock() {
            Ok(db) => service::record_telemetry(&request, Some(&db)),
            Err(error) => Err(CliErrorKind::workflow_io(format!(
                "telemetry daemon db lock poisoned: {error}"
            ))
            .into()),
        }
    } else {
        service::record_telemetry(&request, None)
    };
    timed_json(
        "POST",
        http_paths::DAEMON_TELEMETRY,
        &request_id,
        start,
        result,
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
    let result = reconfigure_bridge_async(&request.enable, &request.disable, request.force).await;
    record_audit_result(
        state.async_db.get(),
        AuditEventDraft {
            source: "daemon",
            category: "bridgeLifecycle",
            kind: "bridge.reconfigure",
            action_key: "bridge.reconfigure",
            title: "Reconfigure host bridge".to_owned(),
            subject: Some("hostBridge".to_owned()),
            actor: Some("Harness Monitor".to_owned()),
            payload_json: Some(serde_json::json!({
                "enable": request.enable,
                "disable": request.disable,
                "force": request.force,
            })),
            related_urls: Vec::new(),
        },
        &result,
    )
    .await;
    timed_json(
        "POST",
        http_paths::BRIDGE_RECONFIGURE,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/daemon/log-level",
    tag = "daemon",
    responses(
        (status = 200, description = "Current daemon log level", body = LogLevelResponse),
        (status = 401, description = "Missing or invalid daemon token", body = DaemonErrorBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn get_log_level(
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
        http_paths::DAEMON_LOG_LEVEL,
        &request_id,
        start,
        service::get_log_level(),
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    put,
    path = "/v1/daemon/log-level",
    tag = "daemon",
    request_body = SetLogLevelRequest,
    responses(
        (status = 200, description = "Updated daemon log level", body = LogLevelResponse),
        (status = 401, description = "Missing or invalid daemon token", body = DaemonErrorBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn put_log_level(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SetLogLevelRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = service::set_log_level(&request, &state.sender);
    record_audit_result(
        state.async_db.get(),
        AuditEventDraft {
            source: "daemon",
            category: "daemonLifecycle",
            kind: "daemon.set_log_level",
            action_key: "daemon.set_log_level",
            title: "Set daemon log level".to_owned(),
            subject: Some(request.level.clone()),
            actor: Some("Harness Monitor".to_owned()),
            payload_json: Some(serde_json::json!({ "level": request.level })),
            related_urls: Vec::new(),
        },
        &result,
    )
    .await;
    timed_json(
        "PUT",
        http_paths::DAEMON_LOG_LEVEL,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/projects",
    tag = "daemon",
    responses(
        (status = 200, description = "Projects and their worktrees", body = Vec<ProjectSummary>),
        (status = 401, description = "Missing or invalid daemon token", body = DaemonErrorBody),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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
