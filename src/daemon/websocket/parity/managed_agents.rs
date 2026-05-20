use crate::daemon::http::ensure_acp_enabled;
use crate::errors::CliError;

use super::{
    AcpAgentStartRequest, AcpPermissionDecision, CodexApprovalDecisionRequest, CodexRunRequest,
    CodexSteerRequest, DaemonHttpState, ManagedAgentSnapshot, WsRequest, WsResponse,
    bind_control_plane_actor_value, ensure_acp_agent, ensure_codex_agent, ensure_terminal_agent,
    error_response, extract_managed_agent_id, extract_session_id, extract_string_param,
};

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
    let result = state
        .agent_tui_manager
        .start(&session_id, &body)
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
    let result = with_managed_agent_lock(state, &session_id, "codex:start", || {
        state
            .codex_controller
            .start_run(&session_id, &body)
            .map(ManagedAgentSnapshot::Codex)
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
    let result = with_managed_agent_lock(state, &session_id, &body.agent, || {
        state
            .acp_agent_manager
            .start(&session_id, &body)
            .map(ManagedAgentSnapshot::Acp)
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
    let result = match terminal_session_id(state, &agent_id) {
        Ok(session_id) => {
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                state
                    .agent_tui_manager
                    .input(&agent_id, &body)
                    .map(ManagedAgentSnapshot::Terminal)
            })
            .await
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
    let result = match terminal_session_id(state, &agent_id) {
        Ok(session_id) => {
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                state
                    .agent_tui_manager
                    .resize(&agent_id, &body)
                    .map(ManagedAgentSnapshot::Terminal)
            })
            .await
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
    let result = match terminal_session_id(state, &agent_id) {
        Ok(session_id) => {
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                state
                    .agent_tui_manager
                    .signal_ready(&agent_id)
                    .map(ManagedAgentSnapshot::Terminal)
            })
            .await
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
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                state
                    .codex_controller
                    .steer(&agent_id, &body)
                    .map(ManagedAgentSnapshot::Codex)
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
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                state
                    .codex_controller
                    .interrupt(&agent_id)
                    .map(ManagedAgentSnapshot::Codex)
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
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                state
                    .codex_controller
                    .resolve_approval(&agent_id, &approval_id, &body)
                    .map(ManagedAgentSnapshot::Codex)
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
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                state
                    .acp_agent_manager
                    .stop(&agent_id)
                    .map(ManagedAgentSnapshot::Acp)
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
    if let Err(error) = ensure_acp_enabled() {
        return error_response(&request.id, error.code(), &error.message());
    }
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
    let result = match acp_session_id(state, &agent_id) {
        Ok(session_id) => {
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                state
                    .acp_agent_manager
                    .resolve_permission_batch(&agent_id, &batch_id, &decision)
                    .map(ManagedAgentSnapshot::Acp)
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_managed_agent_response(request, state, result).await
}

async fn with_managed_agent_lock<T>(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    let _guard = state
        .managed_agent_mutation_locks
        .lock(session_id, agent_id)
        .await;
    action()
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
    if let Ok(session_id) = state
        .openrouter_agent_manager
        .get(agent_id)
        .map(|snapshot| snapshot.session_id)
    {
        return stop_openrouter_managed_agent(state, &session_id, agent_id).await;
    }
    let session_id = terminal_session_id(state, agent_id)?;
    stop_terminal_managed_agent(state, &session_id, agent_id).await
}

async fn stop_openrouter_managed_agent(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    with_managed_agent_lock(state, session_id, agent_id, || {
        state
            .openrouter_agent_manager
            .cancel(agent_id)
            .map(ManagedAgentSnapshot::OpenRouter)
    })
    .await
}

async fn stop_codex_managed_agent(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    with_managed_agent_lock(state, session_id, agent_id, || {
        state
            .codex_controller
            .stop(agent_id)
            .map(ManagedAgentSnapshot::Codex)
    })
    .await
}

async fn stop_acp_managed_agent(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    with_managed_agent_lock(state, session_id, agent_id, || {
        state
            .acp_agent_manager
            .stop(agent_id)
            .map(ManagedAgentSnapshot::Acp)
    })
    .await
}

async fn stop_terminal_managed_agent(
    state: &DaemonHttpState,
    session_id: &str,
    agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    with_managed_agent_lock(state, session_id, agent_id, || {
        state
            .agent_tui_manager
            .stop(agent_id)
            .map(ManagedAgentSnapshot::Terminal)
    })
    .await
}

fn terminal_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_terminal_agent(state, agent_id)?;
    state
        .agent_tui_manager
        .get(agent_id)
        .map(|snapshot| snapshot.session_id)
}

fn codex_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_codex_agent(state, agent_id)?;
    state
        .codex_controller
        .run(agent_id)
        .map(|snapshot| snapshot.session_id)
}

fn acp_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_acp_agent(state, agent_id)?;
    state
        .acp_agent_manager
        .get(agent_id)
        .map(|snapshot| snapshot.session_id)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(super) async fn dispatch_managed_agent_response(
    request: &WsRequest,
    state: &DaemonHttpState,
    result: Result<ManagedAgentSnapshot, CliError>,
) -> WsResponse {
    match result {
        Ok(snapshot) => {
            tracing::info!(
                method = %request.method,
                request_id = %request.id,
                kind = %managed_agent_snapshot_kind(&snapshot),
                runtime_id = %snapshot.agent_id(),
                session_id = %snapshot.session_id(),
                "managed agent dispatch returning snapshot"
            );
            if let Err(error) =
                super::broadcast_session_snapshot(state, snapshot.session_id()).await
            {
                return super::cli_error_response(&request.id, &error);
            }
            super::dispatch_query_result(&request.id, Ok::<_, CliError>(snapshot))
        }
        Err(error) => super::cli_error_response(&request.id, &error),
    }
}

const fn managed_agent_snapshot_kind(snapshot: &ManagedAgentSnapshot) -> &'static str {
    match snapshot {
        ManagedAgentSnapshot::Terminal(_) => "terminal",
        ManagedAgentSnapshot::Codex(_) => "codex",
        ManagedAgentSnapshot::Acp(_) => "acp",
        ManagedAgentSnapshot::OpenRouter(_) => "openrouter",
    }
}
