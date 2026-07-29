use std::time::Instant;

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;

use crate::agents::acp::probe::AcpRuntimeProbeResponse;
use crate::daemon::acp_probe::probe_acp_agents_cached;
use crate::daemon::audit_events::{AuditEventDraft, record_audit_result};
use crate::daemon::bridge::BridgeStatusReport;
use crate::daemon::bridge::reconfigure_bridge_async;
use crate::daemon::protocol::{
    DaemonControlResponse, GitHubApiDiagnostics, HostBridgeReconfigureRequest, LogLevelResponse,
    SetLogLevelRequest, WsConfigPayload, http_paths,
};
use crate::daemon::service;
use crate::daemon::websocket::build_config_payload;
use harness_kernel::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_json};

#[utoipa::path(
    get,
    path = "/v1/config",
    tag = "daemon",
    description = "Return the initial configuration payload for newly connecting clients: personas, per-runtime model catalogs, ACP agents, and the ACP runtime probe",
    responses(
        (status = 200, description = "Initial configuration payload: personas, per-runtime model catalogs, ACP agents, and the ACP runtime probe", body = WsConfigPayload),
    ),
)]
pub(super) async fn get_config(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
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
    path = "/v1/bridge/reconfigure",
    tag = "daemon",
    description = "Enable or disable specific host bridge projects and return the resulting bridge status. The outcome is also recorded as a bridgeLifecycle audit event",
    request_body = HostBridgeReconfigureRequest,
    responses(
        (status = 200, description = "Host bridge status after reconfiguration", body = BridgeStatusReport),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_bridge_reconfigure(
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
