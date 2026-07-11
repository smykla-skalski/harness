use crate::daemon::protocol::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitHubTokensSyncResponse,
    TaskBoardGitIdentityDefaultsResponse, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeConfigResponse, TaskBoardGitRuntimeDrainSecretsResponse,
    TaskBoardGitSigningVerifyRequest, TaskBoardGitSigningVerifyResponse,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
    TaskBoardOrchestratorSettingsResponse, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardOrchestratorStatusResponse, TaskBoardTodoistTokenSyncRequest,
    TaskBoardTodoistTokenSyncResponse,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::run_blocking;

pub(crate) async fn orchestrator_status() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    run_blocking(
        "orchestrator status",
        service::task_board_orchestrator_status,
    )
    .await
}

pub(crate) async fn start_orchestrator() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    run_blocking("orchestrator start", service::start_task_board_orchestrator).await
}

pub(crate) async fn stop_orchestrator() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    run_blocking("orchestrator stop", service::stop_task_board_orchestrator).await
}

pub(crate) async fn orchestrator_settings()
-> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    run_blocking(
        "orchestrator settings",
        service::task_board_orchestrator_settings,
    )
    .await
}

pub(crate) async fn update_orchestrator_settings(
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    let request = request.clone();
    run_blocking("orchestrator settings update", move || {
        service::update_task_board_orchestrator_settings(&request)
    })
    .await
}

pub(crate) async fn runtime_config() -> Result<TaskBoardGitRuntimeConfigResponse, CliError> {
    run_blocking("runtime config", service::task_board_git_runtime_config).await
}

pub(crate) async fn update_runtime_config(
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfigResponse, CliError> {
    let request = request.clone();
    run_blocking("runtime config update", move || {
        service::update_task_board_git_runtime_config(&request)
    })
    .await
}

pub(crate) async fn sync_github_tokens(
    request: &TaskBoardGitHubTokensSyncRequest,
) -> Result<TaskBoardGitHubTokensSyncResponse, CliError> {
    let request = request.clone();
    run_blocking("github tokens sync", move || {
        service::sync_task_board_github_tokens(&request)
    })
    .await
}

pub(crate) async fn sync_todoist_token(
    request: &TaskBoardTodoistTokenSyncRequest,
) -> Result<TaskBoardTodoistTokenSyncResponse, CliError> {
    let request = request.clone();
    run_blocking("todoist token sync", move || {
        service::sync_task_board_todoist_token(&request)
    })
    .await
}

pub(crate) async fn sync_openrouter_token(
    request: &TaskBoardOpenRouterTokenSyncRequest,
) -> Result<TaskBoardOpenRouterTokenSyncResponse, CliError> {
    let request = request.clone();
    run_blocking("openrouter token sync", move || {
        service::sync_task_board_openrouter_token(&request)
    })
    .await
}

pub(crate) async fn git_identity_defaults() -> Result<TaskBoardGitIdentityDefaultsResponse, CliError>
{
    run_blocking(
        "git identity defaults",
        service::task_board_git_identity_defaults,
    )
    .await
}

pub(crate) async fn verify_git_signing(
    request: &TaskBoardGitSigningVerifyRequest,
) -> Result<TaskBoardGitSigningVerifyResponse, CliError> {
    let request = request.clone();
    run_blocking("git signing verify", move || {
        service::verify_task_board_git_signing(&request)
    })
    .await
}

pub(crate) async fn drain_git_runtime_secrets()
-> Result<TaskBoardGitRuntimeDrainSecretsResponse, CliError> {
    run_blocking(
        "git runtime drain secrets",
        service::drain_task_board_git_runtime_secrets,
    )
    .await
}
