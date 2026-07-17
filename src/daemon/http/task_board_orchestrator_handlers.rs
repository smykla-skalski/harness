use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post, put};
use axum::{Json, Router};

use crate::daemon::protocol::{
    TaskBoardAutomationHistoryRequest, TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeKeyMaterialSyncRequest, TaskBoardGitRuntimeSecretHandoffAckRequest,
    TaskBoardGitSigningVerifyRequest, TaskBoardOpenRouterTokenSyncRequest,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardTodoistTokenSyncRequest, http_paths,
};

use super::DaemonHttpState;
use super::response::timed_json;
use super::task_board::{authenticated_request, authorized_control_request_parts};
use super::task_board_route_executor;

/// Wire the orchestrator and git-identity endpoints onto the task-board router.
/// These handlers live in their own module so `task_board.rs` stays within the
/// file-length cap.
pub(super) fn merge_orchestrator_routes(
    router: Router<DaemonHttpState>,
) -> Router<DaemonHttpState> {
    router
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
            http_paths::TASK_BOARD_ORCHESTRATOR_RUNS,
            get(get_task_board_automation_runs),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
            get(get_task_board_automation_run_detail),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_METRICS,
            get(get_task_board_automation_metrics),
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
            http_paths::TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL,
            put(put_task_board_git_runtime_key_material),
        )
        .route(
            http_paths::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
            post(post_task_board_git_runtime_secret_handoff_prepare),
        )
        .route(
            http_paths::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
            post(post_task_board_git_runtime_secret_handoff_ack),
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
        task_board_route_executor::orchestrator_status(&state).await,
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
        task_board_route_executor::start_orchestrator(&state).await,
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
        task_board_route_executor::stop_orchestrator(&state).await,
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
    let result = Box::pin(super::task_board_orchestrator_run_once::run(
        &state, &request,
    ))
    .await;
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        &request_id,
        start,
        result,
    )
}

async fn get_task_board_automation_runs(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(request): Query<TaskBoardAutomationHistoryRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNS,
        &request_id,
        start,
        task_board_route_executor::automation_runs(&state, &request).await,
    )
}

async fn get_task_board_automation_run_detail(
    Path(run_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
        &request_id,
        start,
        task_board_route_executor::automation_run_detail(&state, &run_id).await,
    )
}

async fn get_task_board_automation_metrics(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_METRICS,
        &request_id,
        start,
        task_board_route_executor::automation_metrics(&state).await,
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
        task_board_route_executor::orchestrator_settings(&state).await,
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
        task_board_route_executor::update_orchestrator_settings(&state, &request).await,
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
        task_board_route_executor::runtime_config(&state).await,
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
        task_board_route_executor::update_runtime_config(&state, &request).await,
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
        task_board_route_executor::verify_git_signing(&state, &request).await,
    )
}

async fn put_task_board_git_runtime_key_material(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardGitRuntimeKeyMaterialSyncRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_GIT_RUNTIME_KEY_MATERIAL,
        &request_id,
        start,
        task_board_route_executor::sync_git_runtime_key_material(&request).await,
    )
}

async fn post_task_board_git_runtime_secret_handoff_prepare(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
        &request_id,
        start,
        task_board_route_executor::prepare_git_runtime_secret_handoff(&state).await,
    )
}

async fn post_task_board_git_runtime_secret_handoff_ack(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardGitRuntimeSecretHandoffAckRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
        &request_id,
        start,
        task_board_route_executor::acknowledge_git_runtime_secret_handoff(&state, &request).await,
    )
}
