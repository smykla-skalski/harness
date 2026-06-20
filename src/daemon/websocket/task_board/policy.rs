use crate::daemon::http::task_board_route_executor;
use crate::daemon::http::{DaemonHttpState, require_async_db};
use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasSetGlobalEnforcementRequest,
    TaskBoardPolicyExportRequest, TaskBoardPolicyImportRequest,
    TaskBoardPolicyPipelineAuditRequest, TaskBoardPolicyPipelineGetRequest,
    TaskBoardPolicyPipelineGoLiveDiffRequest, TaskBoardPolicyPipelineMakeLiveRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelineReplayRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardPolicyScenarioCreateRequest, TaskBoardPolicyScenarioDeleteRequest,
    TaskBoardPolicyScenarioResetRequest, TaskBoardPolicyScenarioUpdateRequest, WsRequest,
    WsResponse, ws_methods,
};

use super::super::mutations::dispatch_query_result;
use super::{invalid_params, parse_params, parse_params_or_default};

pub(super) async fn dispatch_task_board_policy_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_policy_canvas_method(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_policy_pipeline_method(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_policy_scenario_method(request, state).await {
        return Some(response);
    }
    dispatch_policy_io_method(request, state).await
}

async fn dispatch_policy_scenario_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_SCENARIO_CREATE => {
            Some(dispatch_task_board_policy_scenario_create(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_SCENARIO_UPDATE => {
            Some(dispatch_task_board_policy_scenario_update(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_SCENARIO_DELETE => {
            Some(dispatch_task_board_policy_scenario_delete(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_SCENARIO_RESET => {
            Some(dispatch_task_board_policy_scenario_reset(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_canvas_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_policy_canvas_read_method(request, state).await {
        return Some(response);
    }
    dispatch_policy_canvas_mutate_method(request, state).await
}

async fn dispatch_policy_canvas_read_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_CANVAS_WORKSPACE_GET => {
            Some(dispatch_task_board_policy_canvas_workspace_get(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_CREATE => {
            Some(dispatch_task_board_policy_canvas_create(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_DUPLICATE => {
            Some(dispatch_task_board_policy_canvas_duplicate(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_canvas_mutate_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_CANVAS_RENAME => {
            Some(dispatch_task_board_policy_canvas_rename(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_SET_ACTIVE => {
            Some(dispatch_task_board_policy_canvas_set_active(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_DELETE => {
            Some(dispatch_task_board_policy_canvas_delete(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT => {
            Some(dispatch_task_board_policy_canvas_set_global_enforcement(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_pipeline_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GET => {
            Some(dispatch_task_board_policy_pipeline_get(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT => {
            Some(dispatch_task_board_policy_pipeline_save_draft(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE => {
            Some(dispatch_task_board_policy_pipeline_simulate(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE => {
            Some(dispatch_task_board_policy_pipeline_promote(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_MAKE_LIVE => {
            Some(dispatch_task_board_policy_pipeline_make_live(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GO_LIVE_DIFF => {
            Some(dispatch_task_board_policy_pipeline_go_live_diff(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_REPLAY => {
            Some(dispatch_task_board_policy_pipeline_replay(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT => {
            Some(dispatch_task_board_policy_pipeline_audit(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_io_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_EXPORT => {
            Some(dispatch_task_board_policy_export(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_IMPORT => {
            Some(dispatch_task_board_policy_import(request, state).await)
        }
        _ => None,
    }
}

pub(super) async fn dispatch_task_board_policy_canvas_workspace_get(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(_body) = parse_params_or_default::<TaskBoardPolicyPipelineGetRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas workspace") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::policy_canvas_workspace(db).await,
    )
}

pub(super) async fn dispatch_task_board_policy_canvas_create(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasCreateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas create") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::create_policy_canvas(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_create",
        "Create policy canvas",
        body.title.as_deref(),
        serde_json::json!({ "title": &body.title }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_duplicate(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasDuplicateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas duplicate") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::duplicate_policy_canvas(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_duplicate",
        "Duplicate policy canvas",
        Some(body.canvas_id.as_str()),
        serde_json::json!({
            "canvas_id": &body.canvas_id,
            "title": &body.title,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_rename(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasRenameRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas rename") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::rename_policy_canvas(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_rename",
        "Rename policy canvas",
        Some(body.canvas_id.as_str()),
        serde_json::json!({
            "canvas_id": &body.canvas_id,
            "title": &body.title,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_set_active(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasSetActiveRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas set active") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::set_active_policy_canvas(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_set_active",
        "Set active policy canvas",
        Some(body.canvas_id.as_str()),
        serde_json::json!({ "canvas_id": &body.canvas_id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_delete(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasDeleteRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas delete") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::delete_policy_canvas(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_delete",
        "Delete policy canvas",
        Some(body.canvas_id.as_str()),
        serde_json::json!({ "canvas_id": &body.canvas_id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_canvas_set_global_enforcement(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasSetGlobalEnforcementRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy canvas global enforcement") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::set_policy_canvas_global_enforcement(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_canvas_set_global_enforcement",
        "Set global policy enforcement",
        None,
        serde_json::json!({ "enabled": body.enabled }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

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
    super::record_task_board_audit_result(
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
    super::record_task_board_audit_result(
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
    let db = match require_async_db(state, "policy pipeline promote") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::promote_policy_pipeline(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_pipeline_promote",
        "Promote policy pipeline",
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
    super::record_task_board_audit_result(
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

pub(super) async fn dispatch_task_board_policy_export(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyExportRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy export") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::export_policy_canvas(db, &body).await,
    )
}

pub(super) async fn dispatch_task_board_policy_import(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyImportRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy import") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::import_policy_canvas(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_import",
        "Import policy canvas",
        body.title.as_deref(),
        serde_json::json!({
            "title": &body.title,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_scenario_create(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyScenarioCreateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy scenario create") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::create_policy_scenario(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_scenario_create",
        "Create policy scenario",
        None,
        serde_json::json!({ "name": &body.name }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_scenario_update(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyScenarioUpdateRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy scenario update") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::update_policy_scenario(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_scenario_update",
        "Update policy scenario",
        Some(body.id.as_str()),
        serde_json::json!({ "id": &body.id, "name": &body.name }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_scenario_delete(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyScenarioDeleteRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy scenario delete") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::delete_policy_scenario(db, &body).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_scenario_delete",
        "Delete policy scenario",
        Some(body.id.as_str()),
        serde_json::json!({ "id": &body.id }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_policy_scenario_reset(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(_body) = parse_params_or_default::<TaskBoardPolicyScenarioResetRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy scenario reset") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::reset_policy_scenarios(db).await;
    super::record_task_board_audit_result(
        state,
        "task_board.policy_scenario_reset",
        "Reset policy scenarios",
        None,
        serde_json::json!({}),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}
