//! WebSocket parity for the in-daemon `OpenRouter` agent backend.
//!
//! Mirrors the HTTP routes registered in
//! [`crate::daemon::http::managed_agents`] over the daemon's WebSocket
//! channel so consumers that only speak WS (e.g. the Monitor's primary
//! transport) reach the same operations.

use serde::Deserialize;

use crate::daemon::openrouter_agent::OpenRouterStartRequest;
use crate::errors::CliError;

use super::{
    DaemonHttpState, WsRequest, WsResponse, dispatch_query_result, error_response,
    extract_managed_agent_id, extract_session_id,
};

pub(crate) async fn dispatch_managed_agent_start_openrouter(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body: OpenRouterStartRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = state.openrouter_agent_manager.start(&session_id, body);
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_managed_agent_openrouter_list(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let result: Result<_, CliError> =
        Ok(state.openrouter_agent_manager.list_for_session(&session_id));
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_managed_agent_detail_openrouter(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let result = state.openrouter_agent_manager.get(&agent_id);
    dispatch_query_result(&request.id, result)
}

#[derive(Debug, Clone, Default, Deserialize)]
struct OpenRouterPromptPayload {
    prompt: String,
}

pub(crate) async fn dispatch_managed_agent_prompt_openrouter(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let body: OpenRouterPromptPayload = match serde_json::from_value(request.params.clone()) {
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
        .openrouter_agent_manager
        .prompt(&agent_id, body.prompt);
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_managed_agent_cancel_openrouter(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let result = state.openrouter_agent_manager.cancel(&agent_id);
    dispatch_query_result(&request.id, result)
}
