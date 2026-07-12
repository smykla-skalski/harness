use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardGitRuntimeKeyMaterialSyncRequest, TaskBoardGitRuntimeSecretHandoffAckRequest,
    WsRequest, WsResponse,
};

use super::{invalid_params, parse_params, record_task_board_audit_result};
use crate::daemon::websocket::mutations::dispatch_query_result;

pub(super) async fn dispatch_prepare(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let result = task_board_route_executor::prepare_git_runtime_secret_handoff(state).await;
    record_task_board_audit_result(
        state,
        "task_board.git_runtime_secret_handoff_prepare",
        "Prepare task-board Git runtime secret handoff",
        None,
        serde_json::json!({}),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_ack(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitRuntimeSecretHandoffAckRequest>(request) else {
        return invalid_params(request);
    };
    let result =
        task_board_route_executor::acknowledge_git_runtime_secret_handoff(state, &body).await;
    record_task_board_audit_result(
        state,
        "task_board.git_runtime_secret_handoff_ack",
        "Acknowledge task-board Git runtime secret handoff",
        Some(&body.migration_id),
        serde_json::json!({ "migration_id": body.migration_id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_key_material_sync(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitRuntimeKeyMaterialSyncRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::sync_git_runtime_key_material(&body).await;
    record_task_board_audit_result(
        state,
        "task_board.git_runtime_key_material_sync",
        "Sync task-board Git runtime key material",
        None,
        serde_json::json!({
            "repository_override_count": body.runtime.repository_overrides.len()
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}
