use std::time::Instant;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post, put};
use axum::{Json, Router};

use crate::daemon::protocol::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSimulateRequest, TaskBoardTodoistTokenSyncRequest, http_paths,
};
use crate::errors::CliError;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};
use super::task_board_route_executor;

mod items;

use self::items::{
    delete_task_board_item, get_task_board_audit, get_task_board_host_list,
    get_task_board_host_local, get_task_board_item, get_task_board_items, get_task_board_machines,
    get_task_board_projects, post_task_board_dispatch, post_task_board_evaluate,
    post_task_board_item, post_task_board_plan_approve, post_task_board_plan_begin,
    post_task_board_plan_submit, post_task_board_sync, put_task_board_host_set_project_types,
    put_task_board_item,
};

macro_rules! authenticated_request {
    ($headers:expr, $state:expr) => {{
        let start = Instant::now();
        let request_id = extract_request_id(&$headers);
        if let Err(response) = require_auth(&$headers, &$state) {
            return *response;
        }
        (start, request_id)
    }};
}

fn task_board_host_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::TASK_BOARD_HOST_LOCAL,
            get(get_task_board_host_local),
        )
        .route(
            http_paths::TASK_BOARD_HOST_LIST,
            get(get_task_board_host_list),
        )
        .route(
            http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES,
            put(put_task_board_host_set_project_types),
        )
}

pub(super) fn task_board_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::TASK_BOARD_ITEMS,
            post(post_task_board_item).get(get_task_board_items),
        )
        .route(
            http_paths::TASK_BOARD_ITEM,
            get(get_task_board_item)
                .put(put_task_board_item)
                .delete(delete_task_board_item),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_BEGIN,
            post(post_task_board_plan_begin),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_SUBMIT,
            post(post_task_board_plan_submit),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_APPROVE,
            post(post_task_board_plan_approve),
        )
        .route(http_paths::TASK_BOARD_SYNC, post(post_task_board_sync))
        .route(
            http_paths::TASK_BOARD_DISPATCH,
            post(post_task_board_dispatch),
        )
        .route(
            http_paths::TASK_BOARD_EVALUATE,
            post(post_task_board_evaluate),
        )
        .route(http_paths::TASK_BOARD_AUDIT, get(get_task_board_audit))
        .route(
            http_paths::TASK_BOARD_PROJECTS,
            get(get_task_board_projects),
        )
        .route(
            http_paths::TASK_BOARD_MACHINES,
            get(get_task_board_machines),
        )
        .merge(task_board_host_routes())
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
            get(get_task_board_orchestrator_status),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_START,
            post(post_task_board_orchestrator_start),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
            post(post_task_board_orchestrator_stop),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
            post(post_task_board_orchestrator_run_once),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
            get(get_task_board_orchestrator_settings).put(put_task_board_orchestrator_settings),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
            get(get_task_board_orchestrator_runtime_config)
                .put(put_task_board_orchestrator_runtime_config),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS,
            put(put_task_board_orchestrator_github_tokens),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN,
            put(put_task_board_orchestrator_todoist_token),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_PIPELINE,
            get(get_task_board_policy_pipeline).put(put_task_board_policy_pipeline_draft),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_SIMULATE,
            post(post_task_board_policy_simulate),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_PROMOTE,
            post(post_task_board_policy_promote),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_AUDIT,
            get(get_task_board_policy_audit),
        )
}

async fn get_task_board_orchestrator_status(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
        &request_id,
        start,
        task_board_route_executor::orchestrator_status(),
    )
}

async fn post_task_board_orchestrator_start(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_START,
        &request_id,
        start,
        task_board_route_executor::start_orchestrator(),
    )
}

async fn post_task_board_orchestrator_stop(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
        &request_id,
        start,
        task_board_route_executor::stop_orchestrator(),
    )
}

async fn post_task_board_orchestrator_run_once(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardOrchestratorRunOnceRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    request.actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
    let result = super::task_board_orchestrator_run_once::run(&state, &request).await;
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        &request_id,
        start,
        result,
    )
}

async fn get_task_board_orchestrator_settings(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        &request_id,
        start,
        task_board_route_executor::orchestrator_settings(),
    )
}

async fn put_task_board_orchestrator_settings(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardOrchestratorSettingsUpdateRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        &request_id,
        start,
        task_board_route_executor::update_orchestrator_settings(&request),
    )
}

async fn get_task_board_orchestrator_runtime_config(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
        &request_id,
        start,
        task_board_route_executor::runtime_config(),
    )
}

async fn put_task_board_orchestrator_runtime_config(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardGitRuntimeConfig>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
        &request_id,
        start,
        task_board_route_executor::update_runtime_config(&request),
    )
}

async fn put_task_board_orchestrator_github_tokens(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardGitHubTokensSyncRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS,
        &request_id,
        start,
        task_board_route_executor::sync_github_tokens(&request),
    )
}

async fn put_task_board_orchestrator_todoist_token(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardTodoistTokenSyncRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN,
        &request_id,
        start,
        Ok::<_, CliError>(task_board_route_executor::sync_todoist_token(&request)),
    )
}

async fn get_task_board_policy_pipeline(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        &request_id,
        start,
        task_board_route_executor::policy_pipeline(),
    )
}

async fn put_task_board_policy_pipeline_draft(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelineSaveDraftRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        &request_id,
        start,
        task_board_route_executor::save_policy_pipeline_draft(&request),
    )
}

async fn post_task_board_policy_simulate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelineSimulateRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_SIMULATE,
        &request_id,
        start,
        task_board_route_executor::simulate_policy_pipeline(&request),
    )
}

async fn post_task_board_policy_promote(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelinePromoteRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_PROMOTE,
        &request_id,
        start,
        task_board_route_executor::promote_policy_pipeline(&request),
    )
}

async fn get_task_board_policy_audit(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_POLICY_AUDIT,
        &request_id,
        start,
        task_board_route_executor::audit_policy_pipeline(),
    )
}
