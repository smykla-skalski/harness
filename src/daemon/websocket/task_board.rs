use std::sync::{Arc, Mutex};

use crate::daemon::audit_events::{AuditEventDraft, record_audit_result};
use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    ControlPlaneActorRequest, TaskBoardAuditRequest, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardDispatchDeliverRequest,
    TaskBoardDispatchPickRequest, TaskBoardDispatchRequest, TaskBoardEvaluateRequest,
    TaskBoardGitSigningVerifyRequest, TaskBoardHostSetProjectTypesRequest,
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest, TaskBoardResetItemPositionRequest, TaskBoardSetItemPositionRequest,
    TaskBoardSyncRequest, TaskBoardUpdateItemRequest, WsRequest, WsResponse, ws_methods,
};
use crate::errors::CliError;
use serde::de::DeserializeOwned;

use super::connection::ConnectionState;
use super::frames::error_response;
use super::mutations::dispatch_query_result;

mod orchestrator;
mod policy;
mod read;
mod secret_handoff;

#[expect(
    clippy::cognitive_complexity,
    reason = "task-board websocket method dispatch is clearer as an explicit match"
)]
pub(crate) async fn dispatch_task_board_method(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<WsResponse> {
    if let Some(response) = Box::pin(orchestrator::dispatch_method(request, state)).await {
        return Some(response);
    }
    match request.method.as_str() {
        ws_methods::TASK_BOARD_CREATE => Some(dispatch_task_board_create(request, state).await),
        ws_methods::TASK_BOARD_CAPABILITIES => {
            Some(read::dispatch_task_board_capabilities(request, state).await)
        }
        ws_methods::TASK_BOARD_LIST => {
            Some(read::dispatch_task_board_list(request, state, connection).await)
        }
        ws_methods::TASK_BOARD_GET => {
            Some(read::dispatch_task_board_get(request, state, connection).await)
        }
        ws_methods::TASK_BOARD_POSITION_GET => {
            Some(read::dispatch_task_board_position_get(request, state, connection).await)
        }
        ws_methods::TASK_BOARD_POSITION_SET => {
            Some(dispatch_task_board_position_set(request, state).await)
        }
        ws_methods::TASK_BOARD_POSITION_RESET => {
            Some(dispatch_task_board_position_reset(request, state).await)
        }
        ws_methods::TASK_BOARD_UPDATE => Some(dispatch_task_board_update(request, state).await),
        ws_methods::TASK_BOARD_DELETE => Some(dispatch_task_board_delete(request, state).await),
        ws_methods::TASK_BOARD_PLAN_BEGIN => {
            Some(dispatch_task_board_plan_begin(request, state).await)
        }
        ws_methods::TASK_BOARD_PLAN_SUBMIT => {
            Some(dispatch_task_board_plan_submit(request, state).await)
        }
        ws_methods::TASK_BOARD_PLAN_APPROVE => {
            Some(dispatch_task_board_plan_approve(request, state).await)
        }
        ws_methods::TASK_BOARD_PLAN_REVOKE => {
            Some(dispatch_task_board_plan_revoke(request, state).await)
        }
        ws_methods::TASK_BOARD_SYNC => Some(dispatch_task_board_sync(request, state).await),
        ws_methods::TASK_BOARD_DISPATCH => {
            Some(Box::pin(dispatch_task_board_dispatch(request, state)).await)
        }
        ws_methods::TASK_BOARD_DISPATCH_DELIVER => {
            Some(dispatch_task_board_dispatch_deliver(request, state).await)
        }
        ws_methods::TASK_BOARD_DISPATCH_PICK => {
            Some(dispatch_task_board_dispatch_pick(request, state).await)
        }
        ws_methods::TASK_BOARD_EVALUATE => Some(dispatch_task_board_evaluate(request, state).await),
        ws_methods::TASK_BOARD_AUDIT => Some(dispatch_task_board_audit(request, state).await),
        ws_methods::TASK_BOARD_PROJECTS => Some(dispatch_task_board_projects(request, state).await),
        ws_methods::TASK_BOARD_MACHINES => Some(dispatch_task_board_machines(request, state).await),
        ws_methods::TASK_BOARD_HOST_LOCAL => {
            Some(dispatch_task_board_host_local(request, state).await)
        }
        ws_methods::TASK_BOARD_HOST_LIST => {
            Some(dispatch_task_board_host_list(request, state).await)
        }
        ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES => {
            Some(dispatch_task_board_host_set_project_types(request, state).await)
        }
        ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS => {
            Some(dispatch_task_board_git_identity_defaults(request).await)
        }
        ws_methods::TASK_BOARD_GIT_SIGNING_VERIFY => {
            Some(dispatch_task_board_git_signing_verify(request, state).await)
        }
        ws_methods::TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL_SYNC => {
            Some(secret_handoff::dispatch_key_material_sync(request, state).await)
        }
        ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE => {
            Some(secret_handoff::dispatch_prepare(request, state).await)
        }
        ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK => {
            Some(secret_handoff::dispatch_ack(request, state).await)
        }
        _ => Box::pin(policy::dispatch_policy_method(request, state)).await,
    }
}

/// Create and update do not record a WS-layer audit event: the DB layer
/// already records exactly one (either the typed `BuiltInV1` triage
/// decision, or the plain lane-transition audit for non-eligible items) in
/// the very same transaction as the mutation, and REST calls the same
/// executor with no audit call of its own. Recording a second, generic
/// event here would double-audit every eligible create/update and break
/// REST/WS transport parity.
async fn dispatch_task_board_create(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardCreateItemRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::create_item(state, &body).await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_update(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Some(id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_params::<TaskBoardUpdateItemRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::update_item(state, id, &body).await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_position_set(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(item_id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_control_plane_params::<TaskBoardSetItemPositionRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::set_item_position(state, item_id, &body).await,
    )
}

async fn dispatch_task_board_position_reset(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(item_id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_control_plane_params::<TaskBoardResetItemPositionRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::reset_item_position(state, item_id, &body).await,
    )
}

async fn dispatch_task_board_delete(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDeleteItemRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::delete_item(state, &body).await;
    record_task_board_audit_result(
        state,
        "task_board.delete",
        "Delete task-board item",
        Some(body.id.as_str()),
        serde_json::json!({ "id": body.id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_plan_begin(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanBeginRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::begin_planning(state, &body).await;
    record_task_board_audit_result(
        state,
        "task_board.plan_begin",
        "Begin task-board planning",
        Some(body.id.as_str()),
        serde_json::json!({ "id": body.id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_plan_submit(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanSubmitRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::submit_plan(state, &body).await;
    record_task_board_audit_result(
        state,
        "task_board.plan_submit",
        "Submit task-board plan",
        Some(body.id.as_str()),
        serde_json::json!({
            "id": body.id,
            "summary_length": body.summary.chars().count(),
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_plan_approve(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardPlanApproveRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::approve_plan(state, &body).await;
    record_task_board_audit_result(
        state,
        "task_board.plan_approve",
        "Approve task-board plan",
        Some(body.id.as_str()),
        serde_json::json!({
            "id": body.id,
            "approved_by": body.approved_by,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_plan_revoke(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardPlanRevokeRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::revoke_plan(state, &body).await;
    record_task_board_audit_result(
        state,
        "task_board.plan_revoke",
        "Revoke task-board plan",
        Some(body.id.as_str()),
        serde_json::json!({
            "id": body.id,
            "actor": body.actor,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_sync(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::sync(state, &body).await,
    )
}

async fn dispatch_task_board_dispatch(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardDispatchRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::dispatch(state, body).await;
    record_task_board_audit_result(
        state,
        "task_board.dispatch",
        "Dispatch task-board work",
        request
            .params
            .get("item_id")
            .and_then(serde_json::Value::as_str),
        serde_json::json!({ "request": &request.params }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_dispatch_deliver(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDispatchDeliverRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::deliver(state, &body).await,
    )
}

async fn dispatch_task_board_dispatch_pick(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    if parse_params_or_default::<TaskBoardDispatchPickRequest>(request).is_err() {
        return invalid_params(request);
    }
    dispatch_query_result(&request.id, task_board_route_executor::pick(state).await)
}

async fn dispatch_task_board_evaluate(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardEvaluateRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::evaluate(state, body).await;
    record_task_board_audit_result(
        state,
        "task_board.evaluate",
        "Evaluate task-board work",
        request
            .params
            .get("item_id")
            .and_then(serde_json::Value::as_str),
        serde_json::json!({ "request": &request.params }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_audit(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardAuditRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::audit(state, &body).await,
    )
}

async fn dispatch_task_board_projects(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::projects(state, &body).await,
    )
}

async fn dispatch_task_board_machines(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::machines(state, &body).await,
    )
}

async fn dispatch_task_board_host_local(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::host_local(state).await,
    )
}

async fn dispatch_task_board_host_list(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::host_list(state).await,
    )
}

async fn dispatch_task_board_host_set_project_types(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardHostSetProjectTypesRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::host_set_project_types(state, &body).await;
    record_task_board_audit_result(
        state,
        "task_board.host_set_project_types",
        "Update host project types",
        None,
        serde_json::json!({ "project_types": body.project_types }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_git_identity_defaults(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::git_identity_defaults().await,
    )
}

async fn dispatch_task_board_git_signing_verify(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitSigningVerifyRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::verify_git_signing(state, &body).await,
    )
}

pub(super) fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> serde_json::Result<T> {
    serde_json::from_value(request.params.clone())
}

fn parse_control_plane_params<T>(request: &WsRequest) -> serde_json::Result<T>
where
    T: DeserializeOwned + ControlPlaneActorRequest,
{
    let mut body: T = serde_json::from_value(request.params.clone())?;
    body.bind_control_plane_actor();
    Ok(body)
}

pub(super) fn parse_params_or_default<T>(request: &WsRequest) -> serde_json::Result<T>
where
    T: Default + DeserializeOwned,
{
    if request.params.is_null() {
        return Ok(T::default());
    }
    parse_params(request)
}

pub(super) fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid task-board params")
}

pub(super) async fn record_task_board_audit_result<T>(
    state: &DaemonHttpState,
    action_key: &'static str,
    title: &'static str,
    subject: Option<&str>,
    payload_json: serde_json::Value,
    result: &Result<T, CliError>,
) {
    record_audit_result(
        state.async_db.get(),
        AuditEventDraft {
            source: "taskBoard",
            category: "taskBoardMutation",
            kind: action_key,
            action_key,
            title: title.to_owned(),
            subject: subject.map(ToOwned::to_owned),
            actor: Some("Harness Monitor".to_owned()),
            payload_json: Some(payload_json),
            related_urls: Vec::new(),
        },
        result,
    )
    .await;
}

#[cfg(test)]
mod tests;
