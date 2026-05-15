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
use crate::daemon::service;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

mod items;

use self::items::{
    delete_task_board_item, get_task_board_audit, get_task_board_item, get_task_board_items,
    get_task_board_machines, get_task_board_projects, post_task_board_dispatch,
    post_task_board_evaluate, post_task_board_item, post_task_board_sync, put_task_board_item,
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
        service::task_board_orchestrator_status(),
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
        service::start_task_board_orchestrator(),
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
        service::stop_task_board_orchestrator(),
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
        service::task_board_orchestrator_settings(),
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
        service::update_task_board_orchestrator_settings(&request),
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
        service::task_board_git_runtime_config(),
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
        service::update_task_board_git_runtime_config(&request),
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
        service::sync_task_board_github_tokens(&request),
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
        Ok::<_, crate::errors::CliError>(service::sync_task_board_todoist_token(&request)),
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
        service::task_board_policy_pipeline(),
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
        service::save_task_board_policy_pipeline_draft(&request),
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
        service::simulate_task_board_policy_pipeline(&request),
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
        service::promote_task_board_policy_pipeline(&request),
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
        service::audit_task_board_policy_pipeline(),
    )
}
