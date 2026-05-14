use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCatalogRequest, TaskBoardCreateItemRequest,
    TaskBoardDeleteItemRequest, TaskBoardDispatchRequest, TaskBoardEvaluateRequest,
    TaskBoardGetItemRequest, TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardListItemsRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSimulateRequest, TaskBoardSyncRequest, TaskBoardUpdateItemRequest,
    WsRequest, WsResponse, ws_methods,
};
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use serde::de::DeserializeOwned;
use tokio::task::spawn_blocking;

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

async fn dispatch_task_board_sync(request: &WsRequest) -> WsResponse {
    let Ok(body) = parse_params_or_default::<TaskBoardSyncRequest>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(&request.id, service::sync_task_board_async(&body).await)
}

async fn dispatch_task_board_dispatch(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(mut body) = parse_params::<TaskBoardDispatchRequest>(request) else {
        return invalid_params(request);
    };
    body.actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
    let result = if let Some(async_db) = state.async_db.get() {
        let result = service::dispatch_task_board_async(&body, async_db.as_ref()).await;
        if result
            .as_ref()
            .is_ok_and(|response| !response.applied.is_empty())
        {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        result
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        let result = service::dispatch_task_board(&body, db_ref);
        if result
            .as_ref()
            .is_ok_and(|response| !response.applied.is_empty())
        {
            service::broadcast_sessions_updated(&state.sender, db_ref);
        }
        result
    };
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_evaluate(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardEvaluateRequest>(request) else {
        return invalid_params(request);
    };
    let result = if let Some(async_db) = state.async_db.get() {
        let result = service::evaluate_task_board_async(&body, async_db.as_ref()).await;
        if result.as_ref().is_ok_and(|response| response.updated > 0) {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        result
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        let result = service::evaluate_task_board(&body, db_ref);
        if result.as_ref().is_ok_and(|response| response.updated > 0) {
            service::broadcast_sessions_updated(&state.sender, db_ref);
        }
        result
    };
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
    let Ok(mut body) = parse_params::<TaskBoardOrchestratorRunOnceRequest>(request) else {
        return invalid_params(request);
    };
    body.actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
    let result = run_task_board_orchestrator_once_route(state, &body).await;
    dispatch_query_result(&request.id, result)
}

async fn run_task_board_orchestrator_once_route(
    state: &DaemonHttpState,
    body: &TaskBoardOrchestratorRunOnceRequest,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result = service::run_task_board_orchestrator_once_async(body, async_db.as_ref()).await;
        if result
            .as_ref()
            .is_ok_and(|status| status.last_run_applied_count() > 0)
        {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        result
    } else {
        let db = state.db.get().cloned();
        let body_for_worker = body.clone();
        let result = spawn_blocking(move || {
            let db_guard = db.as_ref().map(|db| db.lock().expect("db lock"));
            let db_ref = db_guard.as_deref();
            service::run_task_board_orchestrator_once(&body_for_worker, db_ref)
        })
        .await
        .unwrap_or_else(|error| {
            Err(
                CliErrorKind::workflow_io(format!("run task-board orchestrator fallback: {error}"))
                    .into(),
            )
        });
        if result
            .as_ref()
            .is_ok_and(|status| status.last_run_applied_count() > 0)
        {
            let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
            let db_ref = db_guard.as_deref();
            service::broadcast_sessions_updated(&state.sender, db_ref);
        }
        result
    }
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
