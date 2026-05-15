use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    ControlPlaneActorRequest, TaskBoardAuditRequest, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardDispatchRequest,
    TaskBoardEvaluateRequest, TaskBoardGetItemRequest, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitRuntimeConfig, TaskBoardHostSetProjectTypesRequest, TaskBoardListItemsRequest,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardSyncRequest, TaskBoardTodoistTokenSyncRequest, TaskBoardUpdateItemRequest, WsRequest,
    WsResponse, ws_methods,
};
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
        ws_methods::TASK_BOARD_PLAN_REVOKE => Some(dispatch_task_board_plan_revoke(request)),
        ws_methods::TASK_BOARD_SYNC => Some(dispatch_task_board_sync(request).await),
        ws_methods::TASK_BOARD_DISPATCH => Some(dispatch_task_board_dispatch(request, state).await),
        ws_methods::TASK_BOARD_EVALUATE => Some(dispatch_task_board_evaluate(request, state).await),
        ws_methods::TASK_BOARD_AUDIT => Some(dispatch_task_board_audit(request)),
        ws_methods::TASK_BOARD_PROJECTS => Some(dispatch_task_board_projects(request)),
        ws_methods::TASK_BOARD_MACHINES => Some(dispatch_task_board_machines(request)),
        ws_methods::TASK_BOARD_HOST_LOCAL => Some(dispatch_task_board_host_local(request)),
        ws_methods::TASK_BOARD_HOST_LIST => Some(dispatch_task_board_host_list(request)),
        ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES => {
            Some(dispatch_task_board_host_set_project_types(request))
        }
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
    dispatch_query_result(&request.id, task_board_route_executor::create_item(&body))
}

fn dispatch_task_board_list(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardListItemsRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::list_items(&body))
}

fn dispatch_task_board_get(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGetItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::get_item(&body))
}

fn dispatch_task_board_update(request: &WsRequest) -> WsResponse {
    let Some(id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_params::<TaskBoardUpdateItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::update_item(id, &body),
    )
}

fn dispatch_task_board_delete(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDeleteItemRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::delete_item(&body))
}

fn dispatch_task_board_plan_begin(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanBeginRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::begin_planning(&body),
    )
}

fn dispatch_task_board_plan_submit(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPlanSubmitRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::submit_plan(&body))
}

fn dispatch_task_board_plan_approve(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardPlanApproveRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::approve_plan(&body))
}

fn dispatch_task_board_plan_revoke(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardPlanRevokeRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::revoke_plan(&body))
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

fn dispatch_task_board_audit(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardAuditRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::audit(&body))
}

fn dispatch_task_board_projects(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::projects(&body))
}

fn dispatch_task_board_machines(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardCatalogRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::machines(&body))
}

fn dispatch_task_board_host_local(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, task_board_route_executor::host_local())
}

fn dispatch_task_board_host_list(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, task_board_route_executor::host_list())
}

fn dispatch_task_board_host_set_project_types(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardHostSetProjectTypesRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::host_set_project_types(&body),
    )
}

fn dispatch_task_board_orchestrator_status(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::orchestrator_status(),
    )
}

fn dispatch_task_board_orchestrator_start(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, task_board_route_executor::start_orchestrator())
}

fn dispatch_task_board_orchestrator_stop(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, task_board_route_executor::stop_orchestrator())
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

fn dispatch_task_board_orchestrator_settings_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::orchestrator_settings(),
    )
}

fn dispatch_task_board_orchestrator_settings_update(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOrchestratorSettingsUpdateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::update_orchestrator_settings(&body),
    )
}

fn dispatch_task_board_orchestrator_runtime_config_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, task_board_route_executor::runtime_config())
}

fn dispatch_task_board_orchestrator_runtime_config_update(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitRuntimeConfig>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::update_runtime_config(&body),
    )
}

fn dispatch_task_board_orchestrator_github_tokens_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitHubTokensSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::sync_github_tokens(&body),
    )
}

fn dispatch_task_board_orchestrator_todoist_token_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardTodoistTokenSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, task_board_route_executor::sync_todoist_token(&body))
}

fn dispatch_task_board_policy_pipeline_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(&request.id, task_board_route_executor::policy_pipeline())
}

fn dispatch_task_board_policy_pipeline_save_draft(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSaveDraftRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::save_policy_pipeline_draft(&body),
    )
}

fn dispatch_task_board_policy_pipeline_simulate(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelineSimulateRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::simulate_policy_pipeline(&body),
    )
}

fn dispatch_task_board_policy_pipeline_promote(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardPolicyPipelinePromoteRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::promote_policy_pipeline(&body),
    )
}

fn dispatch_task_board_policy_pipeline_audit(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::audit_policy_pipeline(),
    )
}

fn parse_params<T: DeserializeOwned>(request: &WsRequest) -> serde_json::Result<T> {
    serde_json::from_value(request.params.clone())
}

#[cfg(test)]
const TASK_BOARD_WS_METHOD_CATALOG: &[&str] = &[
    ws_methods::TASK_BOARD_CREATE,
    ws_methods::TASK_BOARD_LIST,
    ws_methods::TASK_BOARD_GET,
    ws_methods::TASK_BOARD_UPDATE,
    ws_methods::TASK_BOARD_DELETE,
    ws_methods::TASK_BOARD_PLAN_BEGIN,
    ws_methods::TASK_BOARD_PLAN_SUBMIT,
    ws_methods::TASK_BOARD_PLAN_APPROVE,
    ws_methods::TASK_BOARD_SYNC,
    ws_methods::TASK_BOARD_DISPATCH,
    ws_methods::TASK_BOARD_EVALUATE,
    ws_methods::TASK_BOARD_AUDIT,
    ws_methods::TASK_BOARD_PROJECTS,
    ws_methods::TASK_BOARD_MACHINES,
    ws_methods::TASK_BOARD_HOST_LOCAL,
    ws_methods::TASK_BOARD_HOST_LIST,
    ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES,
    ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
    ws_methods::TASK_BOARD_ORCHESTRATOR_START,
    ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
    ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
    ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
    ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
    ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
];

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::super::test_support::test_http_state_with_db;
    use super::*;

    #[tokio::test]
    async fn ws_task_board_method_parity_against_constants() {
        let state = test_http_state_with_db();
        for method in TASK_BOARD_WS_METHOD_CATALOG {
            let request = WsRequest {
                id: format!("ws-parity-{method}"),
                method: (*method).to_string(),
                params: json!({}),
                trace_context: None,
            };
            let response = dispatch_task_board_method(&request, &state).await;
            assert!(
                response.is_some(),
                "ws method {method} has no handler arm in dispatch_task_board_method",
            );
        }
    }

    #[tokio::test]
    async fn ws_unknown_task_board_method_returns_none() {
        let state = test_http_state_with_db();
        let request = WsRequest {
            id: "ws-parity-unknown".into(),
            method: "task_board.unknown_method".into(),
            params: json!({}),
            trace_context: None,
        };
        let response = dispatch_task_board_method(&request, &state).await;
        assert!(response.is_none());
    }
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
