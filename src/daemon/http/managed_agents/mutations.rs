use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::agent_acp::AcpPermissionDecision;
use crate::daemon::agent_tui::{AgentTuiInputRequest, AgentTuiResizeRequest, AgentTuiStartRequest};
use crate::daemon::protocol::{
    CodexApprovalDecisionRequest, CodexRunRequest, CodexSteerRequest, ManagedAgentSnapshot,
    http_paths,
};

use super::super::DaemonHttpState;
use super::super::auth::{authorize_control_request, require_auth};
use super::super::response::{extract_request_id, timed_json};
use super::{ensure_acp_agent, ensure_codex_agent, ensure_terminal_agent};

pub(super) async fn post_terminal_agent_start(
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
    let result = state
        .agent_tui_manager
        .start(&session_id, &request)
        .map(ManagedAgentSnapshot::Terminal);
    timed_json(
        "POST",
        http_paths::SESSION_MANAGED_AGENTS_TERMINAL,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_codex_agent_start(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<CodexRunRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = state
        .codex_controller
        .start_run(&session_id, &request)
        .map(ManagedAgentSnapshot::Codex);
    timed_json(
        "POST",
        http_paths::SESSION_MANAGED_AGENTS_CODEX,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_terminal_agent_input(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiInputRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = ensure_terminal_agent(&state, &agent_id)
        .and_then(|()| state.agent_tui_manager.input(&agent_id, &request))
        .map(ManagedAgentSnapshot::Terminal);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_INPUT,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_terminal_agent_resize(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiResizeRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = ensure_terminal_agent(&state, &agent_id)
        .and_then(|()| state.agent_tui_manager.resize(&agent_id, &request))
        .map(ManagedAgentSnapshot::Terminal);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_RESIZE,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_terminal_agent_stop(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = if state.acp_agent_manager.get(&agent_id).is_ok() {
        state
            .acp_agent_manager
            .stop(&agent_id)
            .map(ManagedAgentSnapshot::Acp)
    } else {
        ensure_terminal_agent(&state, &agent_id)
            .and_then(|()| state.agent_tui_manager.stop(&agent_id))
            .map(ManagedAgentSnapshot::Terminal)
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_STOP,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_terminal_agent_ready(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = ensure_terminal_agent(&state, &agent_id)
        .and_then(|()| state.agent_tui_manager.signal_ready(&agent_id))
        .map(ManagedAgentSnapshot::Terminal);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_READY,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_codex_agent_steer(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<CodexSteerRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = ensure_codex_agent(&state, &agent_id)
        .and_then(|()| state.codex_controller.steer(&agent_id, &request))
        .map(ManagedAgentSnapshot::Codex);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_STEER,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_codex_agent_interrupt(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = ensure_codex_agent(&state, &agent_id)
        .and_then(|()| state.codex_controller.interrupt(&agent_id))
        .map(ManagedAgentSnapshot::Codex);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_INTERRUPT,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_codex_agent_approval(
    Path((agent_id, approval_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<CodexApprovalDecisionRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = ensure_codex_agent(&state, &agent_id)
        .and_then(|()| {
            state
                .codex_controller
                .resolve_approval(&agent_id, &approval_id, &request)
        })
        .map(ManagedAgentSnapshot::Codex);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_APPROVAL,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_acp_permission(
    Path((agent_id, batch_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AcpPermissionDecision>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = ensure_acp_agent(&state, &agent_id)
        .and_then(|()| {
            state
                .acp_agent_manager
                .resolve_permission_batch(&agent_id, &batch_id, &request)
        })
        .map(ManagedAgentSnapshot::Acp);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_ACP_PERMISSION,
        &request_id,
        start,
        result,
    )
}
