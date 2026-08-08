use crate::daemon::http::{DaemonHttpState, require_async_db};
use crate::daemon::protocol::{
    AgentWorkspaceSignalAckRequest, AgentWorkspaceSignalCancelRequest,
    AgentWorkspaceSignalSendRequest, WsRequest, WsResponse, bind_control_plane_actor_value,
};
use crate::daemon::service;

use super::super::super::frames::error_response;
use super::super::super::mutations::dispatch_query_result;
use super::super::super::params::extract_string_param;

pub(in crate::daemon::websocket::dispatch) async fn dispatch_agent_workspace_signal_send(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some((workspace_id, member_id)) = workspace_member_params(request) else {
        return missing_params(&request.id, "missing workspace_id or member_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body = match serde_json::from_value::<AgentWorkspaceSignalSendRequest>(params) {
        Ok(body) => body,
        Err(error) => return invalid_params(&request.id, &error),
    };
    let result = match require_async_db(state, "agent workspace signal") {
        Ok(db) => {
            service::send_agent_workspace_signal_async(
                db,
                &workspace_id,
                &member_id,
                &body,
                state.wake_dispatch(),
            )
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

pub(in crate::daemon::websocket::dispatch) async fn dispatch_agent_workspace_signal_ack(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some((workspace_id, member_id, signal_id)) = workspace_signal_params(request) else {
        return missing_params(&request.id, "missing workspace_id, member_id, or signal_id");
    };
    let body =
        match serde_json::from_value::<AgentWorkspaceSignalAckRequest>(request.params.clone()) {
            Ok(body) => body,
            Err(error) => return invalid_params(&request.id, &error),
        };
    let result = match require_async_db(state, "agent workspace signal acknowledgment") {
        Ok(db) => {
            service::acknowledge_agent_workspace_signal_async(
                db,
                &workspace_id,
                &member_id,
                &signal_id,
                &body,
            )
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

pub(in crate::daemon::websocket::dispatch) async fn dispatch_agent_workspace_signal_cancel(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some((workspace_id, member_id, signal_id)) = workspace_signal_params(request) else {
        return missing_params(&request.id, "missing workspace_id, member_id, or signal_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body = match serde_json::from_value::<AgentWorkspaceSignalCancelRequest>(params) {
        Ok(body) => body,
        Err(error) => return invalid_params(&request.id, &error),
    };
    let result = match require_async_db(state, "agent workspace signal cancellation") {
        Ok(db) => {
            service::cancel_agent_workspace_signal_async(
                db,
                &workspace_id,
                &member_id,
                &signal_id,
                &body,
            )
            .await
        }
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

fn workspace_member_params(request: &WsRequest) -> Option<(String, String)> {
    Some((
        extract_string_param(&request.params, "workspace_id")?,
        extract_string_param(&request.params, "member_id")?,
    ))
}

fn workspace_signal_params(request: &WsRequest) -> Option<(String, String, String)> {
    let (workspace_id, member_id) = workspace_member_params(request)?;
    Some((
        workspace_id,
        member_id,
        extract_string_param(&request.params, "signal_id")?,
    ))
}

fn missing_params(request_id: &str, message: &str) -> WsResponse {
    error_response(request_id, "MISSING_PARAM", message)
}

fn invalid_params(request_id: &str, error: &serde_json::Error) -> WsResponse {
    error_response(
        request_id,
        "INVALID_PARAMS",
        &format!("failed to parse request params: {error}"),
    )
}
