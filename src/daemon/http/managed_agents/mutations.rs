use std::future::Future;
use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::agent_tui::{AgentTuiInputRequest, AgentTuiResizeRequest, AgentTuiStartRequest};
use crate::daemon::agent_tui::AgentTuiInputRequestSchema;
use crate::daemon::protocol::{
    CodexApprovalDecisionRequest, CodexRunRequest, CodexSteerRequest, ManagedAgentSnapshot,
    http_paths,
};
use crate::daemon::protocol::ManagedAgentSnapshotSchema;
use harness_kernel::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::{authorize_control_request, require_auth};
use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_json};
use super::{
    ensure_codex_agent, ensure_terminal_agent_async, run_acp_agent_blocking,
    run_codex_agent_blocking, run_terminal_agent_blocking,
};

#[utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/managed-agents/terminal",
    tag = "managed-agents",
    description = "Start a terminal-backed managed agent (a PTY session) within the given session",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
    ),
    request_body = AgentTuiStartRequest,
    responses(
        (status = 200, description = "Started terminal managed agent", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
    let result = run_terminal_agent_blocking(&state, "start", move |manager| {
        manager.start(&session_id, &request)
    })
    .await
    .map(ManagedAgentSnapshot::Terminal);
    timed_json(
        "POST",
        http_paths::SESSION_MANAGED_AGENTS_TERMINAL,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/managed-agents/codex",
    tag = "managed-agents",
    description = "Start a Codex-backed managed agent run within the given session. Uses control-request authorization rather than the standard bearer check, since the run request itself carries control metadata",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
    ),
    request_body = CodexRunRequest,
    responses(
        (status = 200, description = "Started Codex managed agent", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
    let run_session_id = session_id.clone();
    let result = with_managed_agent_lock(&state, &session_id, "codex:start", || {
        run_codex_agent_blocking(&state, "start", move |controller| {
            controller
                .start_run(&run_session_id, &request)
                .map(ManagedAgentSnapshot::Codex)
        })
    })
    .await;
    timed_json(
        "POST",
        http_paths::SESSION_MANAGED_AGENTS_CODEX,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/input",
    tag = "managed-agents",
    description = "Send input bytes to a running terminal-backed managed agent's PTY and return the updated snapshot",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
    ),
    request_body = AgentTuiInputRequestSchema,
    responses(
        (status = 200, description = "Terminal agent snapshot after input", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_terminal_agent_input(
    Path(managed_agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiInputRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match ensure_terminal_agent_async(&state, &managed_agent_id).await {
        Ok(()) => {
            let agent_id = managed_agent_id.clone();
            run_terminal_agent_blocking(&state, "input", move |manager| {
                manager.input(&agent_id, &request)
            })
            .await
            .map(ManagedAgentSnapshot::Terminal)
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_INPUT,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/resize",
    tag = "managed-agents",
    description = "Resize a running terminal-backed managed agent's PTY and return the updated snapshot",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
    ),
    request_body = AgentTuiResizeRequest,
    responses(
        (status = 200, description = "Terminal agent snapshot after resize", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_terminal_agent_resize(
    Path(managed_agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiResizeRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match ensure_terminal_agent_async(&state, &managed_agent_id).await {
        Ok(()) => {
            let agent_id = managed_agent_id.clone();
            run_terminal_agent_blocking(&state, "resize", move |manager| {
                manager.resize(&agent_id, &request)
            })
            .await
            .map(ManagedAgentSnapshot::Terminal)
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_RESIZE,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/stop",
    tag = "managed-agents",
    description = "Stop a managed agent, probing the Codex, ACP, and terminal agent managers in turn to locate which backend owns the given identifier",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
    ),
    responses(
        (status = 200, description = "Managed agent snapshot after stop", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
#[expect(
    clippy::cognitive_complexity,
    reason = "managed-agent stop probes codex, ACP, then terminal managers explicitly"
)]
pub(super) async fn post_terminal_agent_stop(
    Path(managed_agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match state.codex_controller.session_id_for_run(&managed_agent_id) {
        Ok(session_id) => {
            let agent_id = managed_agent_id.clone();
            with_managed_agent_lock(&state, &session_id, &managed_agent_id, || {
                run_codex_agent_blocking(&state, "stop", move |controller| {
                    controller.stop(&agent_id).map(ManagedAgentSnapshot::Codex)
                })
            })
            .await
        }
        Err(error) if error.code() == "KSRCLI090" => {
            if let Ok(snapshot) = state.acp_agent_manager.get(&managed_agent_id) {
                let session_id = snapshot.session_id;
                let agent_id = managed_agent_id.clone();
                with_managed_agent_lock(&state, &session_id, &managed_agent_id, || {
                    run_acp_agent_blocking(&state, "stop", move |manager| {
                        manager.stop(&agent_id).map(ManagedAgentSnapshot::Acp)
                    })
                })
                .await
            } else {
                match ensure_terminal_agent_async(&state, &managed_agent_id).await {
                    Ok(()) => {
                        let agent_id = managed_agent_id.clone();
                        run_terminal_agent_blocking(&state, "stop", move |manager| {
                            manager.stop(&agent_id)
                        })
                        .await
                        .map(ManagedAgentSnapshot::Terminal)
                    }
                    Err(error) => Err(error),
                }
            }
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_STOP,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/ready",
    tag = "managed-agents",
    description = "Signal that a terminal-backed managed agent has finished its startup sequence and is ready for input",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
    ),
    responses(
        (status = 200, description = "Terminal agent snapshot after readiness signal", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_terminal_agent_ready(
    Path(managed_agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match ensure_terminal_agent_async(&state, &managed_agent_id).await {
        Ok(()) => {
            let agent_id = managed_agent_id.clone();
            run_terminal_agent_blocking(&state, "ready", move |manager| {
                manager.signal_ready(&agent_id)
            })
            .await
            .map(ManagedAgentSnapshot::Terminal)
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_READY,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/steer",
    tag = "managed-agents",
    description = "Send an additional steering prompt to a running Codex-backed managed agent run",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
    ),
    request_body = CodexSteerRequest,
    responses(
        (status = 200, description = "Codex agent snapshot after steering prompt", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_codex_agent_steer(
    Path(managed_agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<CodexSteerRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match codex_session_id(&state, &managed_agent_id) {
        Ok(session_id) => {
            let agent_id = managed_agent_id.clone();
            with_managed_agent_lock(&state, &session_id, &managed_agent_id, || {
                run_codex_agent_blocking(&state, "steer", move |controller| {
                    controller
                        .steer(&agent_id, &request)
                        .map(ManagedAgentSnapshot::Codex)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_STEER,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/interrupt",
    tag = "managed-agents",
    description = "Interrupt the current turn of a running Codex-backed managed agent run",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
    ),
    responses(
        (status = 200, description = "Codex agent snapshot after interrupt", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
    let result = match codex_session_id(&state, &agent_id) {
        Ok(session_id) => {
            let run_id = agent_id.clone();
            with_managed_agent_lock(&state, &session_id, &agent_id, || {
                run_codex_agent_blocking(&state, "interrupt", move |controller| {
                    controller
                        .interrupt(&run_id)
                        .map(ManagedAgentSnapshot::Codex)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_INTERRUPT,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/approvals/{approval_id}",
    tag = "managed-agents",
    description = "Resolve a pending Codex approval request (for example an exec or patch approval) with the caller's decision",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
        ("approval_id" = String, Path, description = "Pending approval identifier"),
    ),
    request_body = CodexApprovalDecisionRequest,
    responses(
        (status = 200, description = "Codex agent snapshot after resolving the approval", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
    let result = match codex_session_id(&state, &agent_id) {
        Ok(session_id) => {
            let run_id = agent_id.clone();
            let approval_id = approval_id.clone();
            with_managed_agent_lock(&state, &session_id, &agent_id, || {
                run_codex_agent_blocking(&state, "approval", move |controller| {
                    controller
                        .resolve_approval(&run_id, &approval_id, &request)
                        .map(ManagedAgentSnapshot::Codex)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_APPROVAL,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn with_managed_agent_lock<T, Fut>(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
    action: impl FnOnce() -> Fut,
) -> Result<T, CliError>
where
    Fut: Future<Output = Result<T, CliError>>,
{
    let _guard = state
        .managed_agent_mutation_locks
        .lock(session_id, agent_id)
        .await;
    action().await
}

fn codex_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_codex_agent(state, agent_id)?;
    Ok(state.codex_controller.run(agent_id)?.session_id)
}
