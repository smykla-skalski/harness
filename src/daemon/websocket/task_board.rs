use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    ControlPlaneActorRequest, TaskBoardAuditRequest, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardDispatchRequest,
    TaskBoardEvaluateRequest, TaskBoardGetItemRequest, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitRuntimeConfig, TaskBoardGitSigningVerifyRequest,
    TaskBoardHostSetProjectTypesRequest, TaskBoardListItemsRequest,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardPlanApproveRequest,
    TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest,
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyPipelineAuditRequest,
    TaskBoardPolicyPipelineGetRequest, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardSyncRequest, TaskBoardTodoistTokenSyncRequest, TaskBoardUpdateItemRequest, WsRequest,
    WsResponse, ws_methods,
};
use serde::de::DeserializeOwned;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

#[expect(
    clippy::cognitive_complexity,
    reason = "task-board websocket method dispatch is clearer as an explicit match"
)]
pub(crate) async fn dispatch_task_board_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_CREATE => Some(dispatch_task_board_create(request).await),
        ws_methods::TASK_BOARD_LIST => Some(dispatch_task_board_list(request).await),
        ws_methods::TASK_BOARD_GET => Some(dispatch_task_board_get(request).await),
        ws_methods::TASK_BOARD_UPDATE => Some(dispatch_task_board_update(request).await),
        ws_methods::TASK_BOARD_DELETE => Some(dispatch_task_board_delete(request).await),
        ws_methods::TASK_BOARD_PLAN_BEGIN => Some(dispatch_task_board_plan_begin(request).await),
        ws_methods::TASK_BOARD_PLAN_SUBMIT => Some(dispatch_task_board_plan_submit(request).await),
        ws_methods::TASK_BOARD_PLAN_APPROVE => {
            Some(dispatch_task_board_plan_approve(request).await)
        }
        ws_methods::TASK_BOARD_PLAN_REVOKE => Some(dispatch_task_board_plan_revoke(request).await),
        ws_methods::TASK_BOARD_SYNC => Some(dispatch_task_board_sync(request).await),
        ws_methods::TASK_BOARD_DISPATCH => Some(dispatch_task_board_dispatch(request, state).await),
        ws_methods::TASK_BOARD_EVALUATE => Some(dispatch_task_board_evaluate(request, state).await),
        ws_methods::TASK_BOARD_AUDIT => Some(dispatch_task_board_audit(request).await),
        ws_methods::TASK_BOARD_PROJECTS => Some(dispatch_task_board_projects(request).await),
        ws_methods::TASK_BOARD_MACHINES => Some(dispatch_task_board_machines(request).await),
        ws_methods::TASK_BOARD_HOST_LOCAL => Some(dispatch_task_board_host_local(request).await),
        ws_methods::TASK_BOARD_HOST_LIST => Some(dispatch_task_board_host_list(request).await),
        ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES => {
            Some(dispatch_task_board_host_set_project_types(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS => {
            Some(dispatch_task_board_orchestrator_status(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_START => {
            Some(dispatch_task_board_orchestrator_start(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_STOP => {
            Some(dispatch_task_board_orchestrator_stop(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE => {
            Some(dispatch_task_board_orchestrator_run_once(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET => {
            Some(dispatch_task_board_orchestrator_settings_get(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE => {
            Some(dispatch_task_board_orchestrator_settings_update(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET => {
            Some(dispatch_task_board_orchestrator_runtime_config_get(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE => {
            Some(dispatch_task_board_orchestrator_runtime_config_update(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC => {
            Some(dispatch_task_board_orchestrator_github_tokens_sync(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC => {
            Some(dispatch_task_board_orchestrator_todoist_token_sync(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN_SYNC => {
            Some(dispatch_task_board_orchestrator_openrouter_token_sync(request).await)
        }
        ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS => {
            Some(dispatch_task_board_git_identity_defaults(request).await)
        }
        ws_methods::TASK_BOARD_GIT_SIGNING_VERIFY => {
            Some(dispatch_task_board_git_signing_verify(request).await)
        }
        ws_methods::TASK_BOARD_GIT_RUNTIME_DRAIN_SECRETS => {
            Some(dispatch_task_board_git_runtime_drain_secrets(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_WORKSPACE_GET => {
            Some(dispatch_task_board_policy_canvas_workspace_get(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_CREATE => {
            Some(dispatch_task_board_policy_canvas_create(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_DUPLICATE => {
            Some(dispatch_task_board_policy_canvas_duplicate(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_RENAME => {
            Some(dispatch_task_board_policy_canvas_rename(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_SET_ACTIVE => {
            Some(dispatch_task_board_policy_canvas_set_active(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_DELETE => {
            Some(dispatch_task_board_policy_canvas_delete(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GET => {
            Some(dispatch_task_board_policy_pipeline_get(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT => {
            Some(dispatch_task_board_policy_pipeline_save_draft(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE => {
            Some(dispatch_task_board_policy_pipeline_simulate(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE => {
            Some(dispatch_task_board_policy_pipeline_promote(request).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT => {
            Some(dispatch_task_board_policy_pipeline_audit(request).await)
        }
        _ => None,
    }
}

async fn dispatch_task_board_create(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardCreateItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::create_item(&body).await,
    )
}

async fn dispatch_task_board_list(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardListItemsRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::list_items(&body).await,
    )
}

async fn dispatch_task_board_get(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGetItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::get_item(&body).await,
    )
}

async fn dispatch_task_board_update(request: &WsRequest) -> WsResponse {
    let Some(id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_params::<TaskBoardUpdateItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::update_item(id, &body).await,
    )
}

async fn dispatch_task_board_delete(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDeleteItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::delete_item(&body).await,
    )
}

async fn dispatch_task_board_plan_begin(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanBeginRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::begin_planning(&body).await,
    )
}

async fn dispatch_task_board_plan_submit(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanSubmitRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::submit_plan(&body).await,
    )
}

async fn dispatch_task_board_plan_approve(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardPlanApproveRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::approve_plan(&body).await,
    )
}

async fn dispatch_task_board_plan_revoke(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardPlanRevokeRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::revoke_plan(&body).await,
    )
}

async fn dispatch_task_board_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::sync(&body).await)
}

async fn dispatch_task_board_dispatch(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardDispatchRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::dispatch(state, body).await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_evaluate(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardEvaluateRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::evaluate(state, body).await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_audit(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardAuditRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::audit(&body).await)
}

async fn dispatch_task_board_projects(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::projects(&body).await,
    )
}

async fn dispatch_task_board_machines(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::machines(&body).await,
    )
}

async fn dispatch_task_board_host_local(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, task_board_route_executor::host_local().await)
}

async fn dispatch_task_board_host_list(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, task_board_route_executor::host_list().await)
}

async fn dispatch_task_board_host_set_project_types(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardHostSetProjectTypesRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::host_set_project_types(&body).await,
    )
}

async fn dispatch_task_board_orchestrator_status(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::orchestrator_status().await,
    )
}

async fn dispatch_task_board_orchestrator_start(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::start_orchestrator().await,
    )
}

async fn dispatch_task_board_orchestrator_stop(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::stop_orchestrator().await,
    )
}

async fn dispatch_task_board_orchestrator_run_once(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardOrchestratorRunOnceRequest>(request)
    else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::run_once(state, body).await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_orchestrator_settings_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::orchestrator_settings().await,
    )
}

async fn dispatch_task_board_orchestrator_settings_update(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOrchestratorSettingsUpdateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::update_orchestrator_settings(&body).await,
    )
}

async fn dispatch_task_board_orchestrator_runtime_config_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::runtime_config().await,
    )
}

async fn dispatch_task_board_orchestrator_runtime_config_update(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitRuntimeConfig>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::update_runtime_config(&body).await,
    )
}

async fn dispatch_task_board_orchestrator_github_tokens_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitHubTokensSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::sync_github_tokens(&body).await,
    )
}

async fn dispatch_task_board_orchestrator_todoist_token_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardTodoistTokenSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::sync_todoist_token(&body).await,
    )
}

async fn dispatch_task_board_orchestrator_openrouter_token_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOpenRouterTokenSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::sync_openrouter_token(&body).await,
    )
}

async fn dispatch_task_board_git_identity_defaults(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::git_identity_defaults().await,
    )
}

async fn dispatch_task_board_git_signing_verify(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitSigningVerifyRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::verify_git_signing(&body).await,
    )
}

async fn dispatch_task_board_git_runtime_drain_secrets(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::drain_git_runtime_secrets().await,
    )
}

async fn dispatch_task_board_policy_canvas_workspace_get(request: &WsRequest) -> WsResponse {
    let Ok(_body) = parse_params_or_default::<TaskBoardPolicyPipelineGetRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::policy_canvas_workspace().await,
    )
}

async fn dispatch_task_board_policy_canvas_create(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasCreateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::create_policy_canvas(&body).await,
    )
}

async fn dispatch_task_board_policy_canvas_duplicate(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasDuplicateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::duplicate_policy_canvas(&body).await,
    )
}

async fn dispatch_task_board_policy_canvas_rename(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasRenameRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::rename_policy_canvas(&body).await,
    )
}

async fn dispatch_task_board_policy_canvas_set_active(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasSetActiveRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::set_active_policy_canvas(&body).await,
    )
}

async fn dispatch_task_board_policy_canvas_delete(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyCanvasDeleteRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::delete_policy_canvas(&body).await,
    )
}

async fn dispatch_task_board_policy_pipeline_get(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyPipelineGetRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::policy_pipeline(&body).await,
    )
}

async fn dispatch_task_board_policy_pipeline_save_draft(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSaveDraftRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::save_policy_pipeline_draft(&body).await,
    )
}

async fn dispatch_task_board_policy_pipeline_simulate(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSimulateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::simulate_policy_pipeline(&body).await,
    )
}

async fn dispatch_task_board_policy_pipeline_promote(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelinePromoteRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::promote_policy_pipeline(&body).await,
    )
}

async fn dispatch_task_board_policy_pipeline_audit(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardPolicyPipelineAuditRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::audit_policy_pipeline(&body).await,
    )
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> serde_json::Result<T> {
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

fn parse_params_or_default<T>(request: &WsRequest) -> serde_json::Result<T>
where
    T: Default + DeserializeOwned,
{
    if request.params.is_null() {
        return Ok(T::default());
    }
    parse_params(request)
}

fn invalid_params(request: &WsRequest) -> WsResponse {
    error_response(&request.id, "INVALID_PARAMS", "invalid task-board params")
}

#[cfg(test)]
mod tests;
