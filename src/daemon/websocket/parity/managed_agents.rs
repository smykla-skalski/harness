use super::{
    AcpAgentStartRequest, AcpPermissionDecision, CodexApprovalDecisionRequest, CodexRunRequest,
    CodexSteerRequest, DaemonHttpState, ManagedAgentSnapshot, WsRequest, WsResponse,
    bind_control_plane_actor_value, dispatch_managed_agent_response, ensure_acp_agent,
    ensure_codex_agent, ensure_terminal_agent, error_response, extract_session_id,
    extract_string_param,
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
    let result = state
        .codex_controller
        .start_run(&session_id, &body)
        .map(ManagedAgentSnapshot::Codex);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_start_acp(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body: AcpAgentStartRequest = match serde_json::from_value(request.params.clone()) {
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
        .acp_agent_manager
        .start(&session_id, &body)
        .map(ManagedAgentSnapshot::Acp);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_input(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
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
    let result = ensure_terminal_agent(state, &agent_id)
        .and_then(|()| state.agent_tui_manager.input(&agent_id, &body))
        .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_resize(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
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
    let result = ensure_terminal_agent(state, &agent_id)
        .and_then(|()| state.agent_tui_manager.resize(&agent_id, &body))
        .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_stop(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let result = if state.acp_agent_manager.get(&agent_id).is_ok() {
        state
            .acp_agent_manager
            .stop(&agent_id)
            .map(ManagedAgentSnapshot::Acp)
    } else {
        ensure_terminal_agent(state, &agent_id)
            .and_then(|()| state.agent_tui_manager.stop(&agent_id))
            .map(ManagedAgentSnapshot::Terminal)
    };
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_ready(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let result = ensure_terminal_agent(state, &agent_id)
        .and_then(|()| state.agent_tui_manager.signal_ready(&agent_id))
        .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_steer_codex(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
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
    let result = ensure_codex_agent(state, &agent_id)
        .and_then(|()| state.codex_controller.steer(&agent_id, &body))
        .map(ManagedAgentSnapshot::Codex);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_interrupt_codex(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let result = ensure_codex_agent(state, &agent_id)
        .and_then(|()| state.codex_controller.interrupt(&agent_id))
        .map(ManagedAgentSnapshot::Codex);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_resolve_codex_approval(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
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
    let result = ensure_codex_agent(state, &agent_id)
        .and_then(|()| {
            state
                .codex_controller
                .resolve_approval(&agent_id, &approval_id, &body)
        })
        .map(ManagedAgentSnapshot::Codex);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_stop_acp(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let result = ensure_acp_agent(state, &agent_id)
        .and_then(|()| state.acp_agent_manager.stop(&agent_id))
        .map(ManagedAgentSnapshot::Acp);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_resolve_acp_permission(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
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
    let result = ensure_acp_agent(state, &agent_id)
        .and_then(|()| {
            state
                .acp_agent_manager
                .resolve_permission_batch(&agent_id, &batch_id, &decision)
        })
        .map(ManagedAgentSnapshot::Acp);
    dispatch_managed_agent_response(request, state, result).await
}
