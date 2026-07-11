use crate::daemon::http::{DaemonHttpState, require_async_db, task_board_route_executor};
use crate::daemon::protocol::{
    PolicyScenarioCreateRequest, PolicyScenarioDeleteRequest, PolicyScenarioResetRequest,
    PolicyScenarioUpdateRequest, WsRequest, WsResponse,
};
use crate::daemon::websocket::mutations::dispatch_query_result;

use super::super::{invalid_params, parse_params, parse_params_or_default};

pub(super) async fn dispatch_policy_scenario_create(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<PolicyScenarioCreateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy scenario create") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::create_policy_scenario(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "policy_scenario.create",
        "Create policy scenario",
        None,
        serde_json::json!({ "name": &body.name }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_policy_scenario_update(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<PolicyScenarioUpdateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy scenario update") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::update_policy_scenario(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "policy_scenario.update",
        "Update policy scenario",
        Some(body.id.as_str()),
        serde_json::json!({ "id": &body.id, "name": &body.name }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_policy_scenario_delete(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<PolicyScenarioDeleteRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy scenario delete") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::delete_policy_scenario(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "policy_scenario.delete",
        "Delete policy scenario",
        Some(body.id.as_str()),
        serde_json::json!({ "id": &body.id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_policy_scenario_reset(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(_body) = parse_params_or_default::<PolicyScenarioResetRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy scenario reset") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::reset_policy_scenarios(db).await;
    super::super::record_task_board_audit_result(
        state,
        "policy_scenario.reset",
        "Reset policy scenarios",
        None,
        serde_json::json!({}),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}
