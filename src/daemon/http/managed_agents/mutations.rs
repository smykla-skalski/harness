use std::future::Future;
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
use crate::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::{authorize_control_request, require_auth};
use super::super::response::{extract_request_id, timed_json};
use super::{
    ensure_acp_agent, ensure_acp_enabled, ensure_codex_agent, ensure_terminal_agent_async,
    run_acp_agent_blocking, run_codex_agent_blocking, run_terminal_agent_blocking,
};

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

async fn with_managed_agent_lock<T, Fut>(
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

fn acp_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_acp_enabled()?;
    ensure_acp_agent(state, agent_id)?;
    state.acp_agent_manager.get(agent_id).map(|s| s.session_id)
}

#[derive(serde::Deserialize)]
pub(super) struct AcpPromptRequestBody {
    pub prompt: String,
}

pub(super) async fn post_acp_agent_prompt(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AcpPromptRequestBody>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match acp_session_id(&state, &agent_id) {
        Ok(session_id) => {
            let prompt = request.prompt;
            let prompt_agent_id = agent_id.clone();
            with_managed_agent_lock(&state, &session_id, &agent_id, || {
                run_acp_agent_blocking(&state, "prompt", move |manager| {
                    manager
                        .send_prompt(&prompt_agent_id, &prompt)
                        .map(ManagedAgentSnapshot::Acp)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_ACP_PROMPT,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_acp_agent_logout(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match acp_session_id(&state, &agent_id) {
        Ok(session_id) => {
            let logout_agent_id = agent_id.clone();
            with_managed_agent_lock(&state, &session_id, &agent_id, || {
                run_acp_agent_blocking(&state, "logout", move |manager| {
                    manager
                        .logout(&logout_agent_id)
                        .map(|()| serde_json::json!({ "ok": true }))
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_ACP_LOGOUT,
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
    let result = match acp_session_id(&state, &agent_id) {
        Ok(session_id) => {
            let decision_agent_id = agent_id.clone();
            let decision_batch_id = batch_id.clone();
            with_managed_agent_lock(&state, &session_id, &agent_id, || {
                run_acp_agent_blocking(&state, "permission", move |manager| {
                    manager
                        .resolve_permission_batch(&decision_agent_id, &decision_batch_id, &request)
                        .map(ManagedAgentSnapshot::Acp)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_ACP_PERMISSION,
        &request_id,
        start,
        result,
    )
}
