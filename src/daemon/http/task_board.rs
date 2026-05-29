use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post, put};
use axum::{Json, Router};

use crate::daemon::protocol::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig, TaskBoardGitSigningVerifyRequest,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardPolicyCanvasCreateRequest,
    TaskBoardPolicyCanvasDeleteRequest, TaskBoardPolicyCanvasDuplicateRequest,
    TaskBoardPolicyCanvasRenameRequest, TaskBoardPolicyCanvasSetActiveRequest,
    TaskBoardPolicyPipelineAuditRequest, TaskBoardPolicyPipelineGetRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSimulateRequest, TaskBoardTodoistTokenSyncRequest, http_paths,
};

use super::DaemonHttpState;
use super::response::timed_json;
use super::task_board_route_executor;

mod items;

use self::items::{
    authenticated_request, authorized_control_request_parts, delete_task_board_item,
    get_task_board_audit, get_task_board_host_list, get_task_board_host_local, get_task_board_item,
    get_task_board_items, get_task_board_machines, get_task_board_projects,
    post_task_board_dispatch, post_task_board_evaluate, post_task_board_item,
    post_task_board_plan_approve, post_task_board_plan_begin, post_task_board_plan_revoke,
    post_task_board_plan_submit, post_task_board_sync, put_task_board_host_set_project_types,
    put_task_board_item,
};

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

#[expect(
    clippy::too_many_lines,
    reason = "route table wires every task-board endpoint in one place"
)]
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
        .route(
            http_paths::TASK_BOARD_PLAN_REVOKE,
            post(post_task_board_plan_revoke),
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
            http_paths::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN,
            put(put_task_board_orchestrator_openrouter_token),
        )
        .route(
            http_paths::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
            get(get_task_board_git_identity_defaults),
        )
        .route(
            http_paths::TASK_BOARD_GIT_SIGNING_VERIFY,
            post(post_task_board_git_signing_verify),
        )
        .route(
            http_paths::TASK_BOARD_GIT_RUNTIME_DRAIN_SECRETS,
            post(post_task_board_git_runtime_drain_secrets),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES,
            get(get_task_board_policy_canvas_workspace),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_CREATE,
            post(post_task_board_policy_canvas_create),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_DUPLICATE,
            post(post_task_board_policy_canvas_duplicate),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_RENAME,
            post(post_task_board_policy_canvas_rename),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_ACTIVE,
            post(post_task_board_policy_canvas_set_active),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_CANVASES_DELETE,
            post(post_task_board_policy_canvas_delete),
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
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
        &request_id,
        start,
        task_board_route_executor::orchestrator_status().await,
    )
}

async fn post_task_board_orchestrator_start(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_START,
        &request_id,
        start,
        task_board_route_executor::start_orchestrator().await,
    )
}

async fn post_task_board_orchestrator_stop(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
        &request_id,
        start,
        task_board_route_executor::stop_orchestrator().await,
    )
}

async fn post_task_board_orchestrator_run_once(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardOrchestratorRunOnceRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
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
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        &request_id,
        start,
        task_board_route_executor::orchestrator_settings().await,
    )
}

async fn put_task_board_orchestrator_settings(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardOrchestratorSettingsUpdateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        &request_id,
        start,
        task_board_route_executor::update_orchestrator_settings(&request).await,
    )
}

async fn get_task_board_orchestrator_runtime_config(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
        &request_id,
        start,
        task_board_route_executor::runtime_config().await,
    )
}

async fn put_task_board_orchestrator_runtime_config(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardGitRuntimeConfig>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG,
        &request_id,
        start,
        task_board_route_executor::update_runtime_config(&request).await,
    )
}

async fn put_task_board_orchestrator_github_tokens(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardGitHubTokensSyncRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS,
        &request_id,
        start,
        task_board_route_executor::sync_github_tokens(&request).await,
    )
}

async fn put_task_board_orchestrator_todoist_token(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardTodoistTokenSyncRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN,
        &request_id,
        start,
        task_board_route_executor::sync_todoist_token(&request).await,
    )
}

async fn put_task_board_orchestrator_openrouter_token(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardOpenRouterTokenSyncRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_OPENROUTER_TOKEN,
        &request_id,
        start,
        task_board_route_executor::sync_openrouter_token(&request).await,
    )
}

async fn get_task_board_git_identity_defaults(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
        &request_id,
        start,
        task_board_route_executor::git_identity_defaults().await,
    )
}

async fn post_task_board_git_signing_verify(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardGitSigningVerifyRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_GIT_SIGNING_VERIFY,
        &request_id,
        start,
        task_board_route_executor::verify_git_signing(&request).await,
    )
}

async fn post_task_board_git_runtime_drain_secrets(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_GIT_RUNTIME_DRAIN_SECRETS,
        &request_id,
        start,
        task_board_route_executor::drain_git_runtime_secrets().await,
    )
}

async fn get_task_board_policy_pipeline(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(request): Query<TaskBoardPolicyPipelineGetRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        &request_id,
        start,
        task_board_route_executor::policy_pipeline(&request).await,
    )
}

async fn get_task_board_policy_canvas_workspace(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_POLICY_CANVASES,
        &request_id,
        start,
        task_board_route_executor::policy_canvas_workspace().await,
    )
}

async fn post_task_board_policy_canvas_create(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasCreateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_CANVASES_CREATE,
        &request_id,
        start,
        task_board_route_executor::create_policy_canvas(&request).await,
    )
}

async fn post_task_board_policy_canvas_duplicate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasDuplicateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_CANVASES_DUPLICATE,
        &request_id,
        start,
        task_board_route_executor::duplicate_policy_canvas(&request).await,
    )
}

async fn post_task_board_policy_canvas_rename(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasRenameRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_CANVASES_RENAME,
        &request_id,
        start,
        task_board_route_executor::rename_policy_canvas(&request).await,
    )
}

async fn post_task_board_policy_canvas_set_active(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasSetActiveRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_CANVASES_ACTIVE,
        &request_id,
        start,
        task_board_route_executor::set_active_policy_canvas(&request).await,
    )
}

async fn post_task_board_policy_canvas_delete(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyCanvasDeleteRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_CANVASES_DELETE,
        &request_id,
        start,
        task_board_route_executor::delete_policy_canvas(&request).await,
    )
}

async fn put_task_board_policy_pipeline_draft(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelineSaveDraftRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        &request_id,
        start,
        task_board_route_executor::save_policy_pipeline_draft(&request).await,
    )
}

async fn post_task_board_policy_simulate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelineSimulateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_SIMULATE,
        &request_id,
        start,
        task_board_route_executor::simulate_policy_pipeline(&request).await,
    )
}

async fn post_task_board_policy_promote(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelinePromoteRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_PROMOTE,
        &request_id,
        start,
        task_board_route_executor::promote_policy_pipeline(&request).await,
    )
}

async fn get_task_board_policy_audit(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(request): Query<TaskBoardPolicyPipelineAuditRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_POLICY_AUDIT,
        &request_id,
        start,
        task_board_route_executor::audit_policy_pipeline(&request).await,
    )
}
