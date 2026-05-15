use crate::daemon::protocol::{
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitHubTokensSyncResponse, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeConfigResponse, TaskBoardOrchestratorSettingsResponse,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorStatusResponse,
    TaskBoardTodoistTokenSyncRequest, TaskBoardTodoistTokenSyncResponse,
};
use crate::daemon::service;
use crate::errors::CliError;

pub(crate) fn orchestrator_status() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    service::task_board_orchestrator_status()
}

pub(crate) fn start_orchestrator() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    service::start_task_board_orchestrator()
}

pub(crate) fn stop_orchestrator() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    service::stop_task_board_orchestrator()
}

pub(crate) fn orchestrator_settings() -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    service::task_board_orchestrator_settings()
}

pub(crate) fn update_orchestrator_settings(
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    service::update_task_board_orchestrator_settings(request)
}

pub(crate) fn runtime_config() -> Result<TaskBoardGitRuntimeConfigResponse, CliError> {
    service::task_board_git_runtime_config()
}

pub(crate) fn update_runtime_config(
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfigResponse, CliError> {
    service::update_task_board_git_runtime_config(request)
}

pub(crate) fn sync_github_tokens(
    request: &TaskBoardGitHubTokensSyncRequest,
) -> Result<TaskBoardGitHubTokensSyncResponse, CliError> {
    service::sync_task_board_github_tokens(request)
}

pub(crate) fn sync_todoist_token(
    request: &TaskBoardTodoistTokenSyncRequest,
) -> Result<TaskBoardTodoistTokenSyncResponse, CliError> {
    service::sync_task_board_todoist_token(request)
}
