//! WebSocket parity dispatch for task-board working-copy obtain/delete.
//!
//! The Monitor drives these over HTTP; the WS twins exist for route parity.
//! They forward the raw service result, matching the reviews local-clone
//! convention.

use serde::de::DeserializeOwned;

use crate::daemon::protocol::{WsRequest, WsResponse, ws_methods};
use crate::daemon::service;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

pub(crate) async fn dispatch_method(request: &WsRequest) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_WORKING_COPIES_LIST => Some(dispatch_query_result(
            &request.id,
            service::list_task_board_working_copies().await,
        )),
        ws_methods::TASK_BOARD_WORKING_COPIES_OBTAIN => {
            Some(dispatch_task_board_working_copies_obtain(request).await)
        }
        ws_methods::TASK_BOARD_WORKING_COPIES_DELETE => {
            Some(dispatch_task_board_working_copies_delete(request).await)
        }
        _ => None,
    }
}

#[derive(serde::Deserialize)]
struct ObtainWorkingCopyPayload {
    repository: String,
    #[serde(default)]
    allow_clone: bool,
}

#[derive(serde::Deserialize)]
struct DeleteWorkingCopyPayload {
    repo_key_segment: String,
}

pub(crate) async fn dispatch_task_board_working_copies_obtain(request: &WsRequest) -> WsResponse {
    let Ok(payload) = parse_params::<ObtainWorkingCopyPayload>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::obtain_task_board_working_copy(&payload.repository, payload.allow_clone).await,
    )
}

pub(crate) async fn dispatch_task_board_working_copies_delete(request: &WsRequest) -> WsResponse {
    let Ok(payload) = parse_params::<DeleteWorkingCopyPayload>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::delete_task_board_working_copy(&payload.repo_key_segment).await,
    )
}

fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid params")
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> Result<T, serde_json::Error> {
    serde_json::from_value(request.params.clone())
}
