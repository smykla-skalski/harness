use std::time::Instant;

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::get;
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

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
use harness_kernel::errors::{CliError, CliErrorKind};

use super::openapi::DaemonErrorBody;
use crate::agents::acp::probe::AcpRuntimeProbeResponse;
use crate::daemon::bridge::BridgeStatusReport;
use crate::daemon::protocol::{
    DaemonControlResponse, DaemonDiagnosticsReport, DaemonTelemetryResponse, GitHubApiDiagnostics,
    HealthResponse, LogLevelResponse, ProjectSummary, WsConfigPayload,
};

use super::auth::{authenticated_remote_client, require_auth};
use super::response::{extract_request_id, timed_json};
use super::stream::stream_global;
use super::{DaemonHttpState, require_async_db};

pub(super) fn core_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .merge(health_routes())
        .merge(daemon_admin_routes())
        .merge(daemon_control_routes())
        .merge(discovery_routes())
}

fn health_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_health))
        .routes(routes!(get_ready))
        .routes(routes!(get_diagnostics))
        .routes(routes!(get_github_status))
}

fn daemon_admin_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(super::audit::get_audit_events))
        .routes(routes!(post_daemon_telemetry))
        .routes(routes!(get_config))
}

fn daemon_control_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(post_stop_daemon))
        .routes(routes!(post_bridge_reconfigure))
        .routes(routes!(get_log_level, put_log_level))
}

fn discovery_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_projects))
        .routes(routes!(get_runtime_session_resolution))
        .routes(routes!(get_runtimes_probe))
        .route(http_paths::WS, get(ws_upgrade_handler))
        .route(http_paths::STREAM, get(stream_global))
}

/// Query parameters for `GET /v1/runtime-sessions/resolve`.
#[derive(utoipa::IntoParams)]
#[into_params(parameter_in = Query)]
#[derive(Debug, serde::Deserialize)]
pub(crate) struct RuntimeSessionResolutionQuery {
    pub runtime_name: String,
    pub runtime_session_id: String,
}

#[utoipa::path(
    get,
    path = "/v1/health",
    tag = "daemon",
    description = "Report the daemon's health snapshot, combining build and version metadata from the manifest with a live database connectivity check",
    responses(
        (status = 200, description = "Daemon health snapshot", body = HealthResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/ready",
    tag = "daemon",
    description = "Report whether the daemon's async database connection is ready to serve requests, along with the current daemon epoch",
    responses(
        (status = 200, description = "Readiness probe", body = ReadinessResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/runtime-sessions/resolve",
    tag = "daemon",
    description = "Resolve a runtime-specific session identifier to the Harness session it belongs to, given the runtime name and runtime session id as query parameters",
    params(RuntimeSessionResolutionQuery),
    responses(
        (status = 200, description = "Runtime-session resolution outcome", body = RuntimeSessionResolutionResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/diagnostics",
    tag = "daemon",
    description = "Return the daemon diagnostics report. The report is redacted before being returned when the authenticated caller is a paired remote viewer client",
    responses(
        (status = 200, description = "Daemon diagnostics report", body = DaemonDiagnosticsReport),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/github/status",
    tag = "daemon",
    description = "Return current GitHub API usage diagnostics tracked by the daemon, such as rate-limit and request counters",
    responses(
        (status = 200, description = "GitHub API usage diagnostics", body = GitHubApiDiagnostics),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/config",
    tag = "daemon",
    description = "Return the initial configuration payload for newly connecting clients: personas, per-runtime model catalogs, ACP agents, and the ACP runtime probe",
    responses(
        (status = 200, description = "Initial configuration payload: personas, per-runtime model catalogs, ACP agents, and the ACP runtime probe", body = WsConfigPayload),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/runtimes/probe",
    tag = "daemon",
    description = "Return the cached probe of ACP coding-agent runtime availability. Results reflect the last periodic probe rather than a live check performed on this request",
    responses(
        (status = 200, description = "ACP runtime availability probe", body = AcpRuntimeProbeResponse),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/daemon/stop",
    tag = "daemon",
    description = "Shut down all active ACP agent sessions, then request daemon shutdown",
    responses(
        (status = 200, description = "Daemon shutdown acknowledged", body = DaemonControlResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/daemon/telemetry",
    tag = "daemon",
    description = "Record a client-submitted telemetry event, persisting it to the daemon database when one is configured",
    request_body = DaemonTelemetryRequest,
    responses(
        (status = 200, description = "Telemetry recorded", body = DaemonTelemetryResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/bridge/reconfigure",
    tag = "daemon",
    description = "Enable or disable specific host bridge projects and return the resulting bridge status. The outcome is also recorded as a bridgeLifecycle audit event",
    request_body = HostBridgeReconfigureRequest,
    responses(
        (status = 200, description = "Host bridge status after reconfiguration", body = BridgeStatusReport),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/daemon/log-level",
    tag = "daemon",
    description = "Return the daemon's current tracing log level",
    responses(
        (status = 200, description = "Current daemon log level", body = LogLevelResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    put,
    path = "/v1/daemon/log-level",
    tag = "daemon",
    description = "Update the daemon's tracing log level at runtime and record the change as an audit event",
    request_body = SetLogLevelRequest,
    responses(
        (status = 200, description = "Updated daemon log level", body = LogLevelResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/projects",
    tag = "daemon",
    description = "List known projects along with their registered worktrees",
    responses(
        (status = 200, description = "Projects and their worktrees", body = Vec<ProjectSummary>),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
