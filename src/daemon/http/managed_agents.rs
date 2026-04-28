use std::cmp::Reverse;
use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::daemon::agent_acp::AcpPermissionDecision;
use crate::daemon::agent_tui::{AgentTuiInputRequest, AgentTuiResizeRequest, AgentTuiStartRequest};
use crate::daemon::protocol::{
    CodexApprovalDecisionRequest, CodexRunRequest, CodexSteerRequest, ManagedAgentListResponse,
    ManagedAgentSnapshot, http_paths,
};
use crate::errors::{CliError, CliErrorKind};

use super::DaemonHttpState;
use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};

mod acp_inspect;
mod acp_start;
mod attach;

pub(super) fn managed_agent_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(http_paths::SESSION_MANAGED_AGENTS, get(get_managed_agents))
        .route(
            http_paths::SESSION_MANAGED_AGENTS_TERMINAL,
            post(post_terminal_agent_start),
        )
        .route(
            http_paths::SESSION_MANAGED_AGENTS_CODEX,
            post(post_codex_agent_start),
        )
        .route(
            http_paths::SESSION_MANAGED_AGENTS_ACP,
            post(acp_start::post_acp_agent_start),
        )
        .route(
            http_paths::MANAGED_AGENT_DETAIL,
            get(get_managed_agent).delete(delete_acp_agent),
        )
        .route(
            http_paths::MANAGED_AGENT_INPUT,
            post(post_terminal_agent_input),
        )
        .route(
            http_paths::MANAGED_AGENT_RESIZE,
            post(post_terminal_agent_resize),
        )
        .route(
            http_paths::MANAGED_AGENT_STOP,
            post(post_terminal_agent_stop),
        )
        .route(
            http_paths::MANAGED_AGENT_READY,
            post(post_terminal_agent_ready),
        )
        .route(
            http_paths::MANAGED_AGENT_ATTACH,
            get(attach::get_terminal_agent_attach),
        )
        .route(
            http_paths::MANAGED_AGENT_STEER,
            post(post_codex_agent_steer),
        )
        .route(
            http_paths::MANAGED_AGENT_INTERRUPT,
            post(post_codex_agent_interrupt),
        )
        .route(
            http_paths::MANAGED_AGENT_APPROVAL,
            post(post_codex_agent_approval),
        )
        .route(
            http_paths::MANAGED_AGENT_ACP_PERMISSION,
            post(post_acp_permission),
        )
        .route(
            http_paths::MANAGED_AGENTS_ACP_INSPECT,
            get(acp_inspect::get_acp_inspect),
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
        http_paths::SESSION_MANAGED_AGENTS,
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
        http_paths::MANAGED_AGENT_DETAIL,
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
        http_paths::SESSION_MANAGED_AGENTS_TERMINAL,
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
        http_paths::SESSION_MANAGED_AGENTS_CODEX,
        &request_id,
        start,
        result,
    )
}

async fn delete_acp_agent(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = ensure_acp_agent(&state, &agent_id)
        .and_then(|()| state.acp_agent_manager.stop(&agent_id))
        .map(ManagedAgentSnapshot::Acp);
    timed_json(
        "DELETE",
        http_paths::MANAGED_AGENT_DELETE,
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
        http_paths::MANAGED_AGENT_INPUT,
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
        http_paths::MANAGED_AGENT_RESIZE,
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
        http_paths::MANAGED_AGENT_READY,
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
        http_paths::MANAGED_AGENT_STEER,
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
        http_paths::MANAGED_AGENT_INTERRUPT,
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
        http_paths::MANAGED_AGENT_APPROVAL,
        &request_id,
        start,
        result,
    )
}

async fn post_acp_permission(
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
        .chain(
            state
                .acp_agent_manager
                .list(session_id)?
                .into_iter()
                .map(ManagedAgentSnapshot::Acp),
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
    if let Ok(snapshot) = state.codex_controller.run(agent_id) {
        return Ok(ManagedAgentSnapshot::Codex(snapshot));
    }
    state
        .acp_agent_manager
        .get(agent_id)
        .map(ManagedAgentSnapshot::Acp)
}

pub(crate) fn ensure_terminal_agent(
    state: &DaemonHttpState,
    agent_id: &str,
) -> Result<(), CliError> {
    if state.agent_tui_manager.get(agent_id).is_ok() {
        return Ok(());
    }
    if state.codex_controller.run(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a codex thread"
        ))
        .into());
    }
    if state.acp_agent_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is an ACP session"
        ))
        .into());
    }
    Err(CliErrorKind::session_not_active(format!("managed agent '{agent_id}' not found")).into())
}

pub(crate) fn ensure_codex_agent(state: &DaemonHttpState, agent_id: &str) -> Result<(), CliError> {
    if state.codex_controller.run(agent_id).is_ok() {
        return Ok(());
    }
    if state.agent_tui_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a terminal session"
        ))
        .into());
    }
    if state.acp_agent_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is an ACP session"
        ))
        .into());
    }
    Err(CliErrorKind::session_not_active(format!("managed agent '{agent_id}' not found")).into())
}

pub(crate) fn ensure_acp_agent(state: &DaemonHttpState, agent_id: &str) -> Result<(), CliError> {
    if state.acp_agent_manager.get(agent_id).is_ok() {
        return Ok(());
    }
    if state.agent_tui_manager.get(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a terminal session"
        ))
        .into());
    }
    if state.codex_controller.run(agent_id).is_ok() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed agent '{agent_id}' is a codex thread"
        ))
        .into());
    }
    Err(CliErrorKind::session_not_active(format!("managed agent '{agent_id}' not found")).into())
}
