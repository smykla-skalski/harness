use std::future::Future;

use crate::daemon::http::{
    ensure_acp_enabled, ensure_terminal_agent_async, run_acp_agent_blocking,
    run_codex_agent_blocking, run_terminal_agent_blocking,
};
use crate::errors::CliError;

use super::{
    AcpAgentStartRequest, AcpPermissionDecision, CodexApprovalDecisionRequest, CodexRunRequest,
    CodexSteerRequest, DaemonHttpState, ManagedAgentSnapshot, WsRequest, WsResponse,
    bind_control_plane_actor_value, ensure_acp_agent, ensure_codex_agent, error_response,
    extract_managed_agent_id, extract_session_id, extract_string_param,
};

mod response;

use response::dispatch_managed_agent_response;

pub(crate) async fn dispatch_managed_agent_start_terminal(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = run_terminal_agent_blocking(state, "ws start", move |manager| {
        manager.start(&session_id, &body)
    })
    .await
    .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_start_codex(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: CodexRunRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let run_session_id = session_id.clone();
    let result = with_managed_agent_lock(state, &session_id, "codex:start", || {
        run_codex_agent_blocking(state, "ws start", move |controller| {
            controller
                .start_run(&run_session_id, &body)
                .map(ManagedAgentSnapshot::Codex)
        })
    })
    .await;
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_start_acp(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    if let Err(error) = ensure_acp_enabled() {
        return error_response(&request.id, error.code(), &error.message());
    }
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    if let Some(params) = params.as_object_mut() {
        params.remove("session_id");
    }
    let body: AcpAgentStartRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    if let Err(error) = state
        .acp_agent_manager
        .ensure_session_accepts_acp_start(&session_id)
    {
        return error_response(&request.id, error.code(), &error.message());
    }
    let start_session_id = session_id.clone();
    let lock_agent_id = body.agent.clone();
    let result = with_managed_agent_lock(state, &session_id, &lock_agent_id, || {
        run_acp_agent_blocking(state, "ws start", move |manager| {
            manager
                .start(&start_session_id, &body)
                .map(ManagedAgentSnapshot::Acp)
        })
    })
    .await;
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_input(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let body = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = match terminal_session_id(state, &agent_id).await {
        Ok(session_id) => {
            let _guard = state
                .managed_agent_mutation_locks
                .lock(&session_id, &agent_id)
                .await;
            run_terminal_agent_blocking(state, "ws input", move |manager| {
                manager.input(&agent_id, &body)
            })
            .await
            .map(ManagedAgentSnapshot::Terminal)
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_resize(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let body = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = match terminal_session_id(state, &agent_id).await {
        Ok(session_id) => {
            let _guard = state
                .managed_agent_mutation_locks
                .lock(&session_id, &agent_id)
                .await;
            run_terminal_agent_blocking(state, "ws resize", move |manager| {
                manager.resize(&agent_id, &body)
            })
            .await
            .map(ManagedAgentSnapshot::Terminal)
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_stop(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let result = stop_any_managed_agent(state, &agent_id).await;
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_ready(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let result = match terminal_session_id(state, &agent_id).await {
        Ok(session_id) => {
            let _guard = state
                .managed_agent_mutation_locks
                .lock(&session_id, &agent_id)
                .await;
            run_terminal_agent_blocking(state, "ws ready", move |manager| {
                manager.signal_ready(&agent_id)
            })
            .await
            .map(ManagedAgentSnapshot::Terminal)
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_steer_codex(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let body: CodexSteerRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = match codex_session_id(state, &agent_id) {
        Ok(session_id) => {
            let run_id = agent_id.clone();
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                run_codex_agent_blocking(state, "ws steer", move |controller| {
                    controller
                        .steer(&run_id, &body)
                        .map(ManagedAgentSnapshot::Codex)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_interrupt_codex(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let result = match codex_session_id(state, &agent_id) {
        Ok(session_id) => {
            let run_id = agent_id.clone();
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                run_codex_agent_blocking(state, "ws interrupt", move |controller| {
                    controller
                        .interrupt(&run_id)
                        .map(ManagedAgentSnapshot::Codex)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_resolve_codex_approval(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let Some(approval_id) = extract_string_param(&request.params, "approval_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing approval_id");
    };
    let body: CodexApprovalDecisionRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = match codex_session_id(state, &agent_id) {
        Ok(session_id) => {
            let run_id = agent_id.clone();
            let approval_id = approval_id.clone();
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                run_codex_agent_blocking(state, "ws approval", move |controller| {
                    controller
                        .resolve_approval(&run_id, &approval_id, &body)
                        .map(ManagedAgentSnapshot::Codex)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_stop_acp(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    if let Err(error) = ensure_acp_enabled() {
        return error_response(&request.id, error.code(), &error.message());
    }
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let result = match acp_session_id(state, &agent_id) {
        Ok(session_id) => {
            let stop_agent_id = agent_id.clone();
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                run_acp_agent_blocking(state, "ws stop", move |manager| {
                    manager.stop(&stop_agent_id).map(ManagedAgentSnapshot::Acp)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_prompt_acp(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    if let Err(error) = ensure_acp_enabled() {
        return error_response(&request.id, error.code(), &error.message());
    }
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let Some(prompt) = extract_string_param(&request.params, "prompt") else {
        return error_response(&request.id, "MISSING_PARAM", "missing prompt");
    };
    let result = match acp_session_id(state, &agent_id) {
        Ok(session_id) => {
            let prompt_agent_id = agent_id.clone();
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                run_acp_agent_blocking(state, "ws prompt", move |manager| {
                    manager
                        .send_prompt(&prompt_agent_id, &prompt)
                        .map(ManagedAgentSnapshot::Acp)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_resolve_acp_permission(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let Some(batch_id) = extract_string_param(&request.params, "batch_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing batch_id");
    };
    let decision: AcpPermissionDecision = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    if let Err(error) = ensure_acp_enabled() {
        return error_response(&request.id, error.code(), &error.message());
    }
    let result = match acp_session_id(state, &agent_id) {
        Ok(session_id) => {
            let decision_agent_id = agent_id.clone();
            let decision_batch_id = batch_id.clone();
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                run_acp_agent_blocking(state, "ws permission", move |manager| {
                    manager
                        .resolve_permission_batch(&decision_agent_id, &decision_batch_id, &decision)
                        .map(ManagedAgentSnapshot::Acp)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
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

async fn stop_any_managed_agent(
    state: &DaemonHttpState,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    match state.codex_controller.session_id_for_run(agent_id) {
        Ok(session_id) => stop_codex_managed_agent(state, &session_id, agent_id).await,
        Err(error) if error.code() == "KSRCLI090" => {
            stop_non_codex_managed_agent(state, agent_id).await
        }
        Err(error) => Err(error),
    }
}

async fn stop_non_codex_managed_agent(
    state: &DaemonHttpState,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    if let Ok(session_id) = state
        .acp_agent_manager
        .get(agent_id)
        .map(|snapshot| snapshot.session_id)
    {
        return stop_acp_managed_agent(state, &session_id, agent_id).await;
    }
    let session_id = terminal_session_id(state, agent_id).await?;
    stop_terminal_managed_agent(state, &session_id, agent_id).await
}

async fn stop_codex_managed_agent(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let stop_agent_id = agent_id.to_string();
    with_managed_agent_lock(state, session_id, agent_id, || {
        run_codex_agent_blocking(state, "ws stop", move |controller| {
            controller
                .stop(&stop_agent_id)
                .map(ManagedAgentSnapshot::Codex)
        })
    })
    .await
}

async fn stop_acp_managed_agent(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let stop_agent_id = agent_id.to_string();
    with_managed_agent_lock(state, session_id, agent_id, || {
        run_acp_agent_blocking(state, "ws stop", move |manager| {
            manager.stop(&stop_agent_id).map(ManagedAgentSnapshot::Acp)
        })
    })
    .await
}

async fn stop_terminal_managed_agent(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let _guard = state
        .managed_agent_mutation_locks
        .lock(session_id, agent_id)
        .await;
    let agent_id = agent_id.to_string();
    run_terminal_agent_blocking(state, "ws stop", move |manager| manager.stop(&agent_id))
        .await
        .map(ManagedAgentSnapshot::Terminal)
}

async fn terminal_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_terminal_agent_async(state, agent_id).await?;
    let agent_id = agent_id.to_string();
    run_terminal_agent_blocking(state, "ws terminal session lookup", move |manager| {
        manager.get(&agent_id).map(|snapshot| snapshot.session_id)
    })
    .await
}

fn codex_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_codex_agent(state, agent_id)?;
    state.codex_controller.run(agent_id).map(|s| s.session_id)
}

fn acp_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_acp_agent(state, agent_id)?;
    state.acp_agent_manager.get(agent_id).map(|s| s.session_id)
}
