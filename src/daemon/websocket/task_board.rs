use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCatalogRequest, TaskBoardCreateItemRequest,
    TaskBoardDeleteItemRequest, TaskBoardDispatchRequest, TaskBoardEvaluateRequest,
    TaskBoardGetItemRequest, TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardListItemsRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardPlanApproveRequest,
    TaskBoardPlanBeginRequest, TaskBoardPlanSubmitRequest, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardSyncRequest, TaskBoardTodoistTokenSyncRequest, TaskBoardUpdateItemRequest, WsRequest,
    WsResponse, ws_methods,
};
use crate::daemon::service;
use crate::errors::CliError;
use serde::de::DeserializeOwned;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

pub(crate) async fn dispatch_task_board_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_CREATE => Some(dispatch_task_board_create(request)),
        ws_methods::TASK_BOARD_LIST => Some(dispatch_task_board_list(request)),
        ws_methods::TASK_BOARD_GET => Some(dispatch_task_board_get(request)),
        ws_methods::TASK_BOARD_UPDATE => Some(dispatch_task_board_update(request)),
        ws_methods::TASK_BOARD_DELETE => Some(dispatch_task_board_delete(request)),
        ws_methods::TASK_BOARD_PLAN_BEGIN => Some(dispatch_task_board_plan_begin(request)),
        ws_methods::TASK_BOARD_PLAN_SUBMIT => Some(dispatch_task_board_plan_submit(request)),
        ws_methods::TASK_BOARD_PLAN_APPROVE => Some(dispatch_task_board_plan_approve(request)),
        ws_methods::TASK_BOARD_SYNC => Some(dispatch_task_board_sync(request).await),
        ws_methods::TASK_BOARD_DISPATCH => Some(dispatch_task_board_dispatch(request, state).await),
        ws_methods::TASK_BOARD_EVALUATE => Some(dispatch_task_board_evaluate(request, state).await),
        ws_methods::TASK_BOARD_AUDIT => Some(dispatch_task_board_audit(request)),
        ws_methods::TASK_BOARD_PROJECTS => Some(dispatch_task_board_projects(request)),
        ws_methods::TASK_BOARD_MACHINES => Some(dispatch_task_board_machines(request)),
        ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS => {
            Some(dispatch_task_board_orchestrator_status(request))
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_START => {
            Some(dispatch_task_board_orchestrator_start(request))
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_STOP => {
            Some(dispatch_task_board_orchestrator_stop(request))
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE => {
            Some(dispatch_task_board_orchestrator_run_once(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET => {
            Some(dispatch_task_board_orchestrator_settings_get(request))
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE => {
            Some(dispatch_task_board_orchestrator_settings_update(request))
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET => {
            Some(dispatch_task_board_orchestrator_runtime_config_get(request))
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE => Some(
            dispatch_task_board_orchestrator_runtime_config_update(request),
        ),
        ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC => {
            Some(dispatch_task_board_orchestrator_github_tokens_sync(request))
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC => {
            Some(dispatch_task_board_orchestrator_todoist_token_sync(request))
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GET => {
            Some(dispatch_task_board_policy_pipeline_get(request))
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT => {
            Some(dispatch_task_board_policy_pipeline_save_draft(request))
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE => {
            Some(dispatch_task_board_policy_pipeline_simulate(request))
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE => {
            Some(dispatch_task_board_policy_pipeline_promote(request))
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT => {
            Some(dispatch_task_board_policy_pipeline_audit(request))
        }
        _ => None,
    }
}

fn dispatch_task_board_create(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardCreateItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::create_task_board_item(&body))
}

fn dispatch_task_board_list(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardListItemsRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::list_task_board_items(&body))
}

fn dispatch_task_board_get(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGetItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::get_task_board_item(&body))
}

fn dispatch_task_board_update(request: &WsRequest) -> WsResponse {
    let Some(id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_params::<TaskBoardUpdateItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::update_task_board_item(id, &body))
}

fn dispatch_task_board_delete(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDeleteItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::delete_task_board_item(&body))
}

fn dispatch_task_board_plan_begin(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanBeginRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::begin_task_board_planning(&body))
}

fn dispatch_task_board_plan_submit(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanSubmitRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::submit_task_board_plan(&body))
}

fn dispatch_task_board_plan_approve(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanApproveRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::approve_task_board_plan(&body))
}

async fn dispatch_task_board_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::sync_task_board_async(&body).await)
}

async fn dispatch_task_board_dispatch(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDispatchRequest>(request) else {
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

fn dispatch_task_board_audit(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardAuditRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::audit_task_board(&body))
}

fn dispatch_task_board_projects(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::list_task_board_projects(&body))
}

fn dispatch_task_board_machines(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::list_task_board_machines(&body))
}

fn dispatch_task_board_orchestrator_status(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, service::task_board_orchestrator_status())
}

fn dispatch_task_board_orchestrator_start(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, service::start_task_board_orchestrator())
}

fn dispatch_task_board_orchestrator_stop(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, service::stop_task_board_orchestrator())
}

async fn dispatch_task_board_orchestrator_run_once(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOrchestratorRunOnceRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::run_once(state, body).await;
    dispatch_query_result(&request.id, result)
}

fn dispatch_task_board_orchestrator_settings_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, service::task_board_orchestrator_settings())
}

fn dispatch_task_board_orchestrator_settings_update(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOrchestratorSettingsUpdateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::update_task_board_orchestrator_settings(&body),
    )
}

fn dispatch_task_board_orchestrator_runtime_config_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, service::task_board_git_runtime_config())
}

fn dispatch_task_board_orchestrator_runtime_config_update(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitRuntimeConfig>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::update_task_board_git_runtime_config(&body),
    )
}

fn dispatch_task_board_orchestrator_github_tokens_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitHubTokensSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::sync_task_board_github_tokens(&body))
}

fn dispatch_task_board_orchestrator_todoist_token_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardTodoistTokenSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        Ok::<_, CliError>(service::sync_task_board_todoist_token(&body)),
    )
}

fn dispatch_task_board_policy_pipeline_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, service::task_board_policy_pipeline())
}

fn dispatch_task_board_policy_pipeline_save_draft(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSaveDraftRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::save_task_board_policy_pipeline_draft(&body),
    )
}

fn dispatch_task_board_policy_pipeline_simulate(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSimulateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::simulate_task_board_policy_pipeline(&body),
    )
}

fn dispatch_task_board_policy_pipeline_promote(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelinePromoteRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        service::promote_task_board_policy_pipeline(&body),
    )
}

fn dispatch_task_board_policy_pipeline_audit(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, service::audit_task_board_policy_pipeline())
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> serde_json::Result<T> {
    serde_json::from_value(request.params.clone())
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
