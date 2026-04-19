use std::cmp::Reverse;
use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::daemon::agent_tui::{AgentTuiInputRequest, AgentTuiResizeRequest, AgentTuiStartRequest};
use crate::daemon::protocol::{
    CodexApprovalDecisionRequest, CodexRunRequest, CodexSteerRequest, ManagedAgentListResponse,
    ManagedAgentSnapshot,
};
use crate::errors::{CliError, CliErrorKind};

use super::DaemonHttpState;
use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};

mod attach;

pub(super) fn managed_agent_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            "/v1/sessions/{session_id}/managed-agents",
            get(get_managed_agents),
        )
        .route(
            "/v1/sessions/{session_id}/managed-agents/terminal",
            post(post_terminal_agent_start),
        )
        .route(
            "/v1/sessions/{session_id}/managed-agents/codex",
            post(post_codex_agent_start),
        )
        .route("/v1/managed-agents/{agent_id}", get(get_managed_agent))
        .route(
            "/v1/managed-agents/{agent_id}/input",
            post(post_terminal_agent_input),
        )
        .route(
            "/v1/managed-agents/{agent_id}/resize",
            post(post_terminal_agent_resize),
        )
        .route(
            "/v1/managed-agents/{agent_id}/stop",
            post(post_terminal_agent_stop),
        )
        .route(
            "/v1/managed-agents/{agent_id}/ready",
            post(post_terminal_agent_ready),
        )
        .route(
            "/v1/managed-agents/{agent_id}/attach",
            get(attach::get_terminal_agent_attach),
        )
        .route(
            "/v1/managed-agents/{agent_id}/steer",
            post(post_codex_agent_steer),
        )
        .route(
            "/v1/managed-agents/{agent_id}/interrupt",
            post(post_codex_agent_interrupt),
        )
        .route(
            "/v1/managed-agents/{agent_id}/approvals/{approval_id}",
            post(post_codex_agent_approval),
        )
}

pub(super) async fn get_managed_agents(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = managed_agent_list_response(&state, &session_id);
    timed_json(
        "GET",
        "/v1/sessions/{id}/managed-agents",
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_managed_agent(
    Path(agent_id): Path<String>,
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
        "/v1/managed-agents/{id}",
        &request_id,
        start,
        managed_agent_snapshot(&state, &agent_id),
    )
}

async fn post_terminal_agent_start(
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
        "/v1/sessions/{id}/managed-agents/terminal",
        &request_id,
        start,
        result,
    )
}

async fn post_codex_agent_start(
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
        "/v1/sessions/{id}/managed-agents/codex",
        &request_id,
        start,
        result,
    )
}

async fn post_terminal_agent_input(
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
        "/v1/managed-agents/{id}/input",
        &request_id,
        start,
        result,
    )
}

async fn post_terminal_agent_resize(
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
        "/v1/managed-agents/{id}/resize",
        &request_id,
        start,
        result,
    )
}

async fn post_terminal_agent_stop(
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
        .and_then(|()| state.agent_tui_manager.stop(&agent_id))
        .map(ManagedAgentSnapshot::Terminal);
    timed_json(
        "POST",
        "/v1/managed-agents/{id}/stop",
        &request_id,
        start,
        result,
    )
}

async fn post_terminal_agent_ready(
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
        "/v1/managed-agents/{id}/ready",
        &request_id,
        start,
        result,
    )
}

async fn post_codex_agent_steer(
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
        "/v1/managed-agents/{id}/steer",
        &request_id,
        start,
        result,
    )
}

async fn post_codex_agent_interrupt(
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
        "/v1/managed-agents/{id}/interrupt",
        &request_id,
        start,
        result,
    )
}

async fn post_codex_agent_approval(
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
        "/v1/managed-agents/{id}/approvals/{id}",
        &request_id,
        start,
        result,
    )
}

fn managed_agent_list_response(
    state: &DaemonHttpState,
    session_id: &str,
) -> Result<ManagedAgentListResponse, CliError> {
    let mut agents: Vec<_> = state
        .agent_tui_manager
        .list(session_id)?
        .tuis
        .into_iter()
        .map(ManagedAgentSnapshot::Terminal)
        .chain(
            state
                .codex_controller
                .list_runs(session_id)?
                .runs
                .into_iter()
                .map(ManagedAgentSnapshot::Codex),
        )
        .collect();
    agents.sort_by_key(|agent| {
        (
            Reverse(agent.updated_at().to_string()),
            agent.session_id().to_string(),
            agent.agent_id().to_string(),
        )
    });
    Ok(ManagedAgentListResponse { agents })
}

fn managed_agent_snapshot(
    state: &DaemonHttpState,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    if let Ok(snapshot) = state.agent_tui_manager.get(agent_id) {
        return Ok(ManagedAgentSnapshot::Terminal(snapshot));
    }
    state
        .codex_controller
        .run(agent_id)
        .map(ManagedAgentSnapshot::Codex)
}

fn ensure_terminal_agent(state: &DaemonHttpState, agent_id: &str) -> Result<(), CliError> {
    if state.agent_tui_manager.get(agent_id).is_ok() {
        return Ok(());
    }
    if state.codex_controller.run(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a codex thread"
        ))
        .into());
    }
    Err(CliErrorKind::session_not_active(format!("managed agent '{agent_id}' not found")).into())
}

fn ensure_codex_agent(state: &DaemonHttpState, agent_id: &str) -> Result<(), CliError> {
    if state.codex_controller.run(agent_id).is_ok() {
        return Ok(());
    }
    if state.agent_tui_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a terminal session"
        ))
        .into());
    }
    Err(CliErrorKind::session_not_active(format!("managed agent '{agent_id}' not found")).into())
}
