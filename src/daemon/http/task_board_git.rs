use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::Json;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeKeyMaterialSyncRequest, TaskBoardGitRuntimeSecretHandoffAckRequest,
    TaskBoardGitSigningVerifyRequest, TaskBoardOpenRouterTokenSyncRequest,
    TaskBoardTodoistTokenSyncRequest, http_paths,
};
use crate::task_board::{
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitIdentityDefaults,
    TaskBoardOpenRouterTokenSyncResponse, TaskBoardTodoistTokenSyncResponse,
};

use super::DaemonHttpState;
use super::openapi::DaemonErrorBody;
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
pub(super) fn merge_git_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router
        .routes(routes!(
            get_task_board_orchestrator_runtime_config,
            put_task_board_orchestrator_runtime_config
        ))
        .routes(routes!(put_task_board_orchestrator_github_tokens))
        .routes(routes!(put_task_board_orchestrator_todoist_token))
        .routes(routes!(put_task_board_orchestrator_openrouter_token))
        .routes(routes!(get_task_board_git_identity_defaults))
        .routes(routes!(post_task_board_git_signing_verify))
        .routes(routes!(put_task_board_git_runtime_key_material))
        .routes(routes!(post_task_board_git_runtime_secret_handoff_prepare))
        .routes(routes!(post_task_board_git_runtime_secret_handoff_ack))
}

#[utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/runtime-config",
    tag = "task-board",
    description = "Read the task-board git runtime configuration (author identity, signing mode, per-repository overrides). Secret fields are never returned; only *_configured presence flags are included",
    responses(
        (status = 200, description = "Current git runtime configuration", body = TaskBoardGitRuntimeConfig),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/runtime-config",
    tag = "task-board",
    description = "Replace the task-board git runtime configuration. Submitted secret fields (SSH/GPG keys, passphrases) are normalized and retained in process memory only; the persisted config and the response strip them down to *_configured flags",
    request_body = TaskBoardGitRuntimeConfig,
    responses(
        (status = 200, description = "Git runtime configuration after the update", body = TaskBoardGitRuntimeConfig),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/github-tokens",
    tag = "task-board",
    description = "Replace the in-memory GitHub token snapshot used for task-board git and API operations, including per-repository token overrides. Tokens are held in process memory only; the response reports configured state and counts, never the token values",
    request_body = TaskBoardGitHubTokensSyncRequest,
    responses(
        (status = 200, description = "Outcome of syncing GitHub repository tokens", body = TaskBoardGitHubTokensSyncResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/todoist-token",
    tag = "task-board",
    description = "Replace the in-memory Todoist API token used by the task-board orchestrator's Todoist inbox sync. The token is held in process memory only; the response reports whether a token is configured, never the token itself",
    request_body = TaskBoardTodoistTokenSyncRequest,
    responses(
        (status = 200, description = "Outcome of syncing the Todoist token", body = TaskBoardTodoistTokenSyncResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/openrouter-token",
    tag = "task-board",
    description = "Replace the in-memory OpenRouter API key used by the task-board orchestrator's OpenRouter-backed managed-agent runtime. The key is held in process memory only; the response reports whether a key is configured, never the key itself",
    request_body = TaskBoardOpenRouterTokenSyncRequest,
    responses(
        (status = 200, description = "Outcome of syncing the OpenRouter token", body = TaskBoardOpenRouterTokenSyncResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/task-board/git/identity-defaults",
    tag = "task-board",
    description = "Discover placeholder git identity and signing defaults from the local git config, gh CLI, SSH keys under ~/.ssh, and environment variables, for pre-filling the runtime-config form. Never returns secret material",
    responses(
        (status = 200, description = "Discovered git identity and signing defaults", body = TaskBoardGitIdentityDefaults),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/task-board/git/signing/verify",
    tag = "task-board",
    description = "Run a dry-run signature check against the git signing profile resolved for the given (or default) repository, so the UI can confirm key, passphrase, and mode line up before saving. Signing failures are reported as a Failed variant in the 200 response rather than as an HTTP error",
    request_body = TaskBoardGitSigningVerifyRequest,
    responses(
        (status = 200, description = "Result of verifying git commit signing", body = TaskBoardGitSigningVerifyResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    put,
    path = "/v1/task-board/git/runtime/key-material",
    tag = "task-board",
    description = "Replace the process-only SSH/GPG key material used for git signing and pushes, without mutating the durable database-backed runtime configuration. Key material lives only in daemon process memory and is lost on restart",
    request_body = TaskBoardGitRuntimeKeyMaterialSyncRequest,
    responses(
        (status = 200, description = "Outcome of syncing git runtime key material", body = TaskBoardGitRuntimeKeyMaterialSyncResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/task-board/git/runtime/secret-handoff/prepare",
    tag = "task-board",
    description = "Prepare a non-destructive handoff of pending legacy plaintext git secrets to the Monitor secure store. If a handoff is pending, the response includes the full runtime config with plaintext SSH/GPG key and passphrase values so Monitor can migrate them into the Keychain; otherwise it returns prepared=false with no runtime data",
    responses(
        (status = 200, description = "Prepared secret-handoff envelope", body = TaskBoardGitRuntimeSecretHandoffPrepareResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/task-board/git/runtime/secret-handoff/ack",
    tag = "task-board",
    description = "Acknowledge that the Monitor secure store received a prepared secret handoff, verified by migration ID and digest. The first acknowledgement for a pending handoff replaces in-memory git secrets from the handoff payload and deletes the legacy plaintext config file; a stale or digest-mismatched migration ID is rejected",
    request_body = TaskBoardGitRuntimeSecretHandoffAckRequest,
    responses(
        (status = 200, description = "Result of acknowledging the secret handoff", body = TaskBoardGitRuntimeSecretHandoffAckResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
