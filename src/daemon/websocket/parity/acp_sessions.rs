//! WebSocket mirrors for the ACP agent-owned credential and session-store
//! mutations: logout, session delete, and session close. Each mirrors the
//! matching HTTP handler in `daemon::http::managed_agents` so the two
//! transports stay at parity.

use crate::daemon::http::{
    DaemonHttpState, ensure_acp_agent, ensure_acp_enabled, run_acp_agent_blocking,
};
use crate::daemon::protocol::{WsRequest, WsResponse};
use crate::daemon::websocket::frames::error_response;
use crate::daemon::websocket::mutations::dispatch_query_result;
use crate::daemon::websocket::params::{extract_managed_agent_id, extract_string_param};
use crate::errors::CliError;

use super::managed_agents::{acp_session_id, with_managed_agent_lock};

pub(crate) async fn dispatch_managed_agent_logout_acp(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    if let Err(error) = ensure_acp_enabled() {
        return error_response(&request.id, error.code(), &error.message());
    }
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    // Logout invalidates the credential shared by the agent's session, so it
    // takes the same per-agent mutation lock the HTTP handler does.
    let result = match acp_session_id(state, &agent_id) {
        Ok(session_id) => {
            let logout_agent_id = agent_id.clone();
            with_managed_agent_lock(state, &session_id, &agent_id, || {
                run_acp_agent_blocking(state, "ws logout", move |manager| {
                    manager
                        .logout(&logout_agent_id)
                        .map(|()| serde_json::json!({ "ok": true }))
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_managed_agent_delete_acp_session(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let Some(agent_session_id) = extract_string_param(&request.params, "agent_session_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_session_id");
    };
    let result = match ensure_acp_session_target(state, &agent_id) {
        Ok(()) => {
            run_acp_agent_blocking(state, "ws session-delete", move |manager| {
                manager
                    .delete_agent_session(&agent_id, &agent_session_id)
                    .map(|()| serde_json::json!({ "ok": true }))
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_managed_agent_close_acp_session(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_managed_agent_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing managed_agent_id");
    };
    let Some(agent_session_id) = extract_string_param(&request.params, "agent_session_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_session_id");
    };
    let result = match ensure_acp_session_target(state, &agent_id) {
        Ok(()) => {
            run_acp_agent_blocking(state, "ws session-close", move |manager| {
                manager
                    .close_agent_session(&agent_id, &agent_session_id)
                    .map(|()| serde_json::json!({ "ok": true }))
            })
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

fn ensure_acp_session_target(state: &DaemonHttpState, agent_id: &str) -> Result<(), CliError> {
    ensure_acp_enabled()?;
    ensure_acp_agent(state, agent_id)
}
