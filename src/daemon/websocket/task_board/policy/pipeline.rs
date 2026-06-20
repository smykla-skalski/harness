use crate::daemon::http::{DaemonHttpState, require_async_db, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardPolicyPipelineAuditRequest, TaskBoardPolicyPipelineGetRequest,
    TaskBoardPolicyPipelineGoLiveDiffRequest, TaskBoardPolicyPipelineMakeLiveRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelineReplayRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest, WsRequest,
    WsResponse,
};
use crate::daemon::websocket::mutations::dispatch_query_result;

use super::super::{invalid_params, parse_params, parse_params_or_default};

pub(super) async fn dispatch_task_board_policy_pipeline_get(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyPipelineGetRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::policy_pipeline(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_pipeline_save_draft(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSaveDraftRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline save draft") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::save_policy_pipeline_draft(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_pipeline_save_draft",
        "Save policy pipeline draft",
        body.canvas_id.as_deref(),
        serde_json::json!({
            "canvas_id": &body.canvas_id,
            "if_revision": body.if_revision,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_pipeline_simulate(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSimulateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline simulate") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::simulate_policy_pipeline(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_pipeline_simulate",
        "Simulate policy pipeline",
        body.canvas_id.as_deref(),
        serde_json::json!({
            "canvas_id": &body.canvas_id,
            "has_document": body.document.is_some(),
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_pipeline_promote(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelinePromoteRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline make live") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::promote_policy_pipeline(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_pipeline_promote",
        "Make policy pipeline live (legacy promote alias)",
        body.canvas_id.as_deref(),
        serde_json::json!({ "canvas_id": &body.canvas_id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_pipeline_make_live(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineMakeLiveRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline make live") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::make_live_policy_pipeline(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "task_board.policy_pipeline_make_live",
        "Make policy pipeline live",
        body.canvas_id.as_deref(),
        serde_json::json!({ "canvas_id": &body.canvas_id, "revision": body.revision }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_pipeline_go_live_diff(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyPipelineGoLiveDiffRequest>(request)
    else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline go live diff") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::go_live_diff_policy_pipeline(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_pipeline_replay(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyPipelineReplayRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline replay") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::replay_policy_pipeline(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_pipeline_audit(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyPipelineAuditRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy pipeline audit") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::audit_policy_pipeline(db, &body).await,
    )
}
