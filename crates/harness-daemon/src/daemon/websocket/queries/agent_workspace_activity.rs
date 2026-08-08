use crate::daemon::http::{DaemonHttpState, require_async_db};
use crate::daemon::protocol::{WsRequest, WsResponse};
use crate::daemon::service;

use super::super::frames::error_response;
use super::super::mutations::dispatch_query_result;
use super::super::params::extract_string_param;
use super::timeline_window_request_from_ws;

pub(super) async fn dispatch_agent_workspace_activity_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(workspace_id) = extract_string_param(&request.params, "workspace_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing workspace_id");
    };
    let timeline_request = timeline_window_request_from_ws(request);
    let result = match require_async_db(state, "agent workspace activity") {
        Ok(db) => {
            service::get_agent_workspace_activity_async(db, &workspace_id, &timeline_request).await
        }
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_agent_workspace_member_activity_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(workspace_id) = extract_string_param(&request.params, "workspace_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing workspace_id");
    };
    let Some(member_id) = extract_string_param(&request.params, "member_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing member_id");
    };
    let result = match require_async_db(state, "agent workspace member activity") {
        Ok(db) => {
            service::get_agent_workspace_member_activity_async(db, &workspace_id, &member_id).await
        }
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}
