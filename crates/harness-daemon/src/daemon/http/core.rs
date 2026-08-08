use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::get;
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

use axum::extract::Query;

use crate::daemon::protocol::{AgentRemoveRequest, RuntimeSessionResolutionResponse, http_paths};
use crate::daemon::remote_diagnostics::project_diagnostics_report;
use crate::daemon::remote_viewer::is_remote_viewer;
use crate::daemon::service;
use harness_daemon_acp_probe::cached_probe_snapshot;
use harness_kernel::errors::CliErrorKind;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceListResponse, AgentWorkspaceTeamResponse, DaemonTelemetryRequest,
    DaemonTelemetryResponse, HealthResponse, ReadinessResponse,
};
use harness_protocol::daemon::{HeadlessReadinessReport, HeadlessReadinessRequest};

use super::openapi::DaemonErrorBody;
use crate::daemon::protocol::{DaemonDiagnosticsReport, ProjectSummary};

use super::auth::{authenticated_remote_client, authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};
use super::stream::stream_global;
use super::{DaemonHttpState, require_async_db};
use crate::daemon::websocket::ws_upgrade_handler;

mod control;

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
        .routes(routes!(post_headless_readiness))
        .routes(routes!(get_diagnostics))
        .routes(routes!(control::get_github_status))
}

fn daemon_admin_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(super::audit::get_audit_events))
        .routes(routes!(post_daemon_telemetry))
        .routes(routes!(control::get_config))
}

fn daemon_control_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(control::post_stop_daemon))
        .routes(routes!(control::post_bridge_reconfigure))
        .routes(routes!(control::get_log_level, control::put_log_level))
}

fn discovery_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_projects))
        .routes(routes!(get_agent_workspaces))
        .routes(routes!(get_agent_workspace_team))
        .routes(routes!(post_agent_workspace_member_remove))
        .merge(super::agent_workspace_activity::routes())
        .routes(routes!(get_runtime_session_resolution))
        .routes(routes!(control::get_runtimes_probe))
        .route(http_paths::WS, get(ws_upgrade_handler))
        .route(
            http_paths::REMOTE_WS,
            get(super::remote_ws::remote_ws_upgrade),
        )
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
    post,
    path = "/v1/headless/readiness",
    tag = "daemon",
    description = "Report every prerequisite for a requested headless agent run without exposing credential values",
    request_body = HeadlessReadinessRequest,
    responses(
        (status = 200, description = "Headless execution readiness report", body = HeadlessReadinessReport),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_headless_readiness(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<HeadlessReadinessRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = async {
        let db = require_async_db(&state, "headless readiness")?;
        let (bridge, orchestrator) = tokio::join!(
            tokio::task::spawn_blocking(crate::daemon::bridge::status_report),
            service::task_board_orchestrator_status_db(db),
        );
        let bridge = bridge.map_err(|error| {
            CliErrorKind::workflow_io(format!("headless readiness bridge task failed: {error}"))
        })??;
        let orchestrator = orchestrator?;
        let probe_snapshot = cached_probe_snapshot();
        let runtime_probe = probe_snapshot
            .as_ref()
            .map_or(service::RuntimeProbe::Pending, service::RuntimeProbe::Ready);
        let (credential, model_available) =
            service::assess_provider_readiness(&request.runtime, &request.model).await;
        Ok(service::build_headless_readiness_report(
            &service::HeadlessReadinessInputs {
                request: &request,
                daemon_version: &state.manifest.version,
                bridge: &bridge,
                runtime_probe,
                credential,
                model_available,
                orchestrator_active: orchestrator.enabled && orchestrator.running,
            },
        ))
    }
    .await;
    timed_json(
        "POST",
        http_paths::HEADLESS_READINESS,
        &request_id,
        start,
        result,
    )
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

#[utoipa::path(
    get,
    path = "/v1/agent-workspaces",
    tag = "daemon",
    description = "List durable agent workspaces, retained legacy provenance, and collision blockers",
    responses(
        (status = 200, description = "Verified durable workspaces and blockers", body = AgentWorkspaceListResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_agent_workspaces(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "agent workspaces") {
        Ok(async_db) => service::list_agent_workspaces_async(async_db).await,
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::AGENT_WORKSPACES,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    get,
    path = "/v1/agent-workspaces/{workspace_id}/team",
    tag = "daemon",
    description = "Return the verified workspace-owned agent team and reconciliation blockers",
    params(("workspace_id" = String, Path, description = "Durable workspace identifier")),
    responses(
        (status = 200, description = "Verified durable agent team", body = AgentWorkspaceTeamResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_agent_workspace_team(
    headers: HeaderMap,
    Path(workspace_id): Path<String>,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let mut result = match require_async_db(&state, "agent workspace team") {
        Ok(async_db) => service::get_agent_workspace_team_async(async_db, &workspace_id).await,
        Err(error) => Err(error),
    };
    if let Ok(response) = &mut result {
        super::managed_agents::hydrate_agent_workspace_team_runtime(&state, response).await;
    }
    timed_json(
        "GET",
        http_paths::AGENT_WORKSPACE_TEAM,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/agent-workspaces/{workspace_id}/members/{member_id}/remove",
    tag = "agents",
    description = "Remove durable workspace membership without stopping the member runtime",
    params(
        ("workspace_id" = String, Path, description = "Durable workspace identifier"),
        ("member_id" = String, Path, description = "Workspace-owned member identifier"),
    ),
    request_body = AgentRemoveRequest,
    responses(
        (status = 200, description = "Updated durable agent team", body = AgentWorkspaceTeamResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_agent_workspace_member_remove(
    headers: HeaderMap,
    Path((workspace_id, member_id)): Path<(String, String)>,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<AgentRemoveRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let mut result = match require_async_db(&state, "agent workspace member removal") {
        Ok(db) => service::remove_agent_workspace_member_async(db, &workspace_id, &member_id).await,
        Err(error) => Err(error),
    };
    if let Ok(response) = &mut result {
        super::managed_agents::hydrate_agent_workspace_team_runtime(&state, response).await;
    }
    timed_json(
        "POST",
        http_paths::AGENT_WORKSPACE_MEMBER_REMOVE,
        &request_id,
        start,
        result,
    )
}
