use crate::daemon::audit_events::{AuditEventDraft, record_audit_result};
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
    TaskBoardSyncRequest, TaskBoardTodoistTokenSyncRequest, TaskBoardUpdateItemRequest, WsRequest,
    WsResponse, ws_methods,
};
use serde::de::DeserializeOwned;

use super::frames::error_response;
use super::mutations::dispatch_query_result;

mod policy;

#[expect(
    clippy::cognitive_complexity,
    reason = "task-board websocket method dispatch is clearer as an explicit match"
)]
pub(crate) async fn dispatch_task_board_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_CREATE => Some(dispatch_task_board_create(request, state).await),
        ws_methods::TASK_BOARD_LIST => Some(dispatch_task_board_list(request).await),
        ws_methods::TASK_BOARD_GET => Some(dispatch_task_board_get(request).await),
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
            Some(dispatch_task_board_orchestrator_settings_update(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET => {
            Some(dispatch_task_board_orchestrator_runtime_config_get(request).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE => {
            Some(dispatch_task_board_orchestrator_runtime_config_update(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC => {
            Some(dispatch_task_board_orchestrator_github_tokens_sync(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC => {
            Some(dispatch_task_board_orchestrator_todoist_token_sync(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN_SYNC => {
            Some(dispatch_task_board_orchestrator_openrouter_token_sync(request, state).await)
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
        _ => policy::dispatch_task_board_policy_method(request, state).await,
    }
}

async fn dispatch_task_board_create(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardCreateItemRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::create_item(&body).await;
    record_task_board_audit_result(
        state,
        "task_board.create",
        "Create task-board item",
        body.id.as_deref().or(Some(body.title.as_str())),
        serde_json::json!({
            "title": body.title,
            "priority": body.priority,
            "project_id": body.project_id,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
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

async fn dispatch_task_board_update(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Some(id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error_response(&request.id, "MISSING_PARAM", "missing id");
    };
    let Ok(body) = parse_params::<TaskBoardUpdateItemRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::update_item(id, &body).await;
    record_task_board_audit_result(
        state,
        "task_board.update",
        "Update task-board item",
        Some(id),
        serde_json::json!({
            "id": id,
            "status": body.status,
            "priority": body.priority,
            "project_id": body.project_id,
            "clear_project_id": body.clear_identity.clear_project_id,
            "clear_session_id": body.clear_identity.clear_session_id,
            "clear_work_item_id": body.clear_identity.clear_work_item_id,
            "clear_planning": body.clear_state.clear_planning,
            "clear_workflow": body.clear_state.clear_workflow,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_delete(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardDeleteItemRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::delete_item(&body).await;
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
    let result = task_board_route_executor::begin_planning(&body).await;
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
    let result = task_board_route_executor::submit_plan(&body).await;
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
    let result = task_board_route_executor::approve_plan(&body).await;
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
    let result = task_board_route_executor::revoke_plan(&body).await;
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

async fn dispatch_task_board_orchestrator_settings_update(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOrchestratorSettingsUpdateRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::update_orchestrator_settings(&body).await;
    record_task_board_audit_result(
        state,
        "task_board.orchestrator_settings_update",
        "Update task-board orchestrator settings",
        None,
        serde_json::json!({
            "has_enabled_workflows": body.enabled_workflows.is_some(),
            "has_dry_run_default": body.dry_run_default.is_some(),
            "has_dispatch_status_filter": body.dispatch_status_filter.is_some(),
            "clear_dispatch_status_filter": body.clear_dispatch_status_filter,
            "has_project_dir": body.project_dir.is_some(),
            "clear_project_dir": body.clear_project_dir,
            "has_github_project": body.github_project.is_some(),
            "has_github_inbox": body.github_inbox.is_some(),
            "has_todoist_inbox": body.todoist_inbox.is_some(),
            "has_policy_version": body.policy_version.is_some(),
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_orchestrator_runtime_config_get(request: &WsRequest) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::runtime_config().await,
    )
}

async fn dispatch_task_board_orchestrator_runtime_config_update(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitRuntimeConfig>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::update_runtime_config(&body).await;
    record_task_board_audit_result(
        state,
        "task_board.orchestrator_runtime_config_update",
        "Update task-board Git runtime config",
        None,
        serde_json::json!({
            "global_profile_empty": body.global.is_empty(),
            "repository_override_count": body.repository_overrides.len(),
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_orchestrator_github_tokens_sync(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitHubTokensSyncRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::sync_github_tokens(&body).await;
    record_task_board_audit_result(
        state,
        "task_board.orchestrator_github_tokens_sync",
        "Sync task-board GitHub tokens",
        None,
        serde_json::json!({
            "global_token_configured": body.global_token.is_some(),
            "repository_token_count": body.repository_tokens.len(),
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_orchestrator_todoist_token_sync(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardTodoistTokenSyncRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::sync_todoist_token(&body).await;
    record_task_board_audit_result(
        state,
        "task_board.orchestrator_todoist_token_sync",
        "Sync task-board Todoist token",
        None,
        serde_json::json!({ "token_configured": body.token.is_some() }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

async fn dispatch_task_board_orchestrator_openrouter_token_sync(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOpenRouterTokenSyncRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::sync_openrouter_token(&body).await;
    record_task_board_audit_result(
        state,
        "task_board.orchestrator_openrouter_token_sync",
        "Sync task-board OpenRouter token",
        None,
        serde_json::json!({ "token_configured": body.token.is_some() }),
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

async fn record_task_board_audit_result<T>(
    state: &DaemonHttpState,
    action_key: &'static str,
    title: &'static str,
    subject: Option<&str>,
    payload_json: serde_json::Value,
    result: &Result<T, crate::errors::CliError>,
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
