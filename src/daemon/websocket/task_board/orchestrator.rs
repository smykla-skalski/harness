use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardTodoistTokenSyncRequest, WsRequest,
    WsResponse, ws_methods,
};

use super::super::mutations::dispatch_query_result;
use super::{invalid_params, parse_control_plane_params, parse_params};

pub(super) async fn dispatch_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS => {
            Some(dispatch_task_board_orchestrator_status(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_START => {
            Some(dispatch_task_board_orchestrator_start(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_STOP => {
            Some(dispatch_task_board_orchestrator_stop(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE => {
            Some(Box::pin(dispatch_task_board_orchestrator_run_once(request, state)).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET => {
            Some(dispatch_task_board_orchestrator_settings_get(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE => {
            Some(dispatch_task_board_orchestrator_settings_update(request, state).await)
        }
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET => {
            Some(dispatch_task_board_orchestrator_runtime_config_get(request, state).await)
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
        _ => None,
    }
}

pub(super) async fn dispatch_task_board_orchestrator_status(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::orchestrator_status(state).await,
    )
}

pub(super) async fn dispatch_task_board_orchestrator_start(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let result = task_board_route_executor::start_orchestrator(state).await;
    super::record_task_board_audit_result(
        state,
        "task_board.orchestrator_start",
        "Start task-board orchestrator",
        None,
        serde_json::json!({}),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_orchestrator_stop(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let result = task_board_route_executor::stop_orchestrator(state).await;
    super::record_task_board_audit_result(
        state,
        "task_board.orchestrator_stop",
        "Stop task-board orchestrator",
        None,
        serde_json::json!({}),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_orchestrator_run_once(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardOrchestratorRunOnceRequest>(request)
    else {
        return invalid_params(request);
    };
    let result = Box::pin(task_board_route_executor::run_once(state, body)).await;
    super::record_task_board_audit_result(
        state,
        "task_board.orchestrator_run_once",
        "Run task-board orchestrator once",
        None,
        serde_json::json!({ "request": &request.params }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}

pub(super) async fn dispatch_task_board_orchestrator_settings_get(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::orchestrator_settings(state).await,
    )
}

pub(super) async fn dispatch_task_board_orchestrator_settings_update(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOrchestratorSettingsUpdateRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::update_orchestrator_settings(state, &body).await;
    super::record_task_board_audit_result(
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

pub(super) async fn dispatch_task_board_orchestrator_runtime_config_get(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::runtime_config(state).await,
    )
}

pub(super) async fn dispatch_task_board_orchestrator_runtime_config_update(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitRuntimeConfig>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::update_runtime_config(state, &body).await;
    super::record_task_board_audit_result(
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

pub(super) async fn dispatch_task_board_orchestrator_github_tokens_sync(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardGitHubTokensSyncRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::sync_github_tokens(&body).await;
    super::record_task_board_audit_result(
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

pub(super) async fn dispatch_task_board_orchestrator_todoist_token_sync(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardTodoistTokenSyncRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::sync_todoist_token(&body).await;
    super::record_task_board_audit_result(
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

pub(super) async fn dispatch_task_board_orchestrator_openrouter_token_sync(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<TaskBoardOpenRouterTokenSyncRequest>(request) else {
        return invalid_params(request);
    };
    let result = task_board_route_executor::sync_openrouter_token(&body).await;
    super::record_task_board_audit_result(
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
