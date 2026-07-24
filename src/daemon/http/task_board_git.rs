use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post, put};
use axum::{Json, Router};

use crate::daemon::protocol::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeKeyMaterialSyncRequest, TaskBoardGitRuntimeSecretHandoffAckRequest,
    TaskBoardGitSigningVerifyRequest, TaskBoardOpenRouterTokenSyncRequest,
    TaskBoardTodoistTokenSyncRequest, http_paths,
};
#[cfg(feature = "openapi")]
use crate::task_board::{
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitIdentityDefaults,
    TaskBoardOpenRouterTokenSyncResponse, TaskBoardTodoistTokenSyncResponse,
};

use super::DaemonHttpState;
#[cfg(feature = "openapi")]
use super::openapi::DaemonErrorBody;
#[cfg(feature = "openapi")]
use crate::daemon::protocol::{
    TaskBoardGitRuntimeKeyMaterialSyncResponse, TaskBoardGitRuntimeSecretHandoffAckResponse,
    TaskBoardGitRuntimeSecretHandoffPrepareResponse, TaskBoardGitSigningVerifyResponse,
};
use super::response::timed_json;
use super::task_board::authenticated_request;
use super::task_board_route_executor;

/// Wire the git-runtime configuration, provider-credential sync, and
/// secret-handoff endpoints onto the task-board router. Split from
/// `task_board_orchestrator_handlers` so both files stay within the
/// file-length cap.
pub(super) fn merge_git_routes(router: Router<DaemonHttpState>) -> Router<DaemonHttpState> {
    router
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/runtime-config",
    tag = "task-board",
    responses(
        (status = 200, description = "Current git runtime configuration", body = TaskBoardGitRuntimeConfig),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/runtime-config",
    tag = "task-board",
    request_body = TaskBoardGitRuntimeConfig,
    responses(
        (status = 200, description = "Git runtime configuration after the update", body = TaskBoardGitRuntimeConfig),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/github-tokens",
    tag = "task-board",
    request_body = TaskBoardGitHubTokensSyncRequest,
    responses(
        (status = 200, description = "Outcome of syncing GitHub repository tokens", body = TaskBoardGitHubTokensSyncResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/todoist-token",
    tag = "task-board",
    request_body = TaskBoardTodoistTokenSyncRequest,
    responses(
        (status = 200, description = "Outcome of syncing the Todoist token", body = TaskBoardTodoistTokenSyncResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/openrouter-token",
    tag = "task-board",
    request_body = TaskBoardOpenRouterTokenSyncRequest,
    responses(
        (status = 200, description = "Outcome of syncing the OpenRouter token", body = TaskBoardOpenRouterTokenSyncResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/git/identity-defaults",
    tag = "task-board",
    responses(
        (status = 200, description = "Discovered git identity and signing defaults", body = TaskBoardGitIdentityDefaults),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/git/signing/verify",
    tag = "task-board",
    request_body = TaskBoardGitSigningVerifyRequest,
    responses(
        (status = 200, description = "Result of verifying git commit signing", body = TaskBoardGitSigningVerifyResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    put,
    path = "/v1/task-board/git/runtime/key-material",
    tag = "task-board",
    request_body = TaskBoardGitRuntimeKeyMaterialSyncRequest,
    responses(
        (status = 200, description = "Outcome of syncing git runtime key material", body = TaskBoardGitRuntimeKeyMaterialSyncResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/git/runtime/secret-handoff/prepare",
    tag = "task-board",
    responses(
        (status = 200, description = "Prepared secret-handoff envelope", body = TaskBoardGitRuntimeSecretHandoffPrepareResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/git/runtime/secret-handoff/ack",
    tag = "task-board",
    request_body = TaskBoardGitRuntimeSecretHandoffAckRequest,
    responses(
        (status = 200, description = "Result of acknowledging the secret handoff", body = TaskBoardGitRuntimeSecretHandoffAckResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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
