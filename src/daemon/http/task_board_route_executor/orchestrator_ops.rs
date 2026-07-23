use crate::daemon::protocol::{
    TaskBoardAutomationForceCancelRequest, TaskBoardAutomationForceCancelResponse,
    TaskBoardAutomationHistoryRequest, TaskBoardAutomationMetricsResponse,
    TaskBoardAutomationRunDetailResponse, TaskBoardAutomationRunsResponse,
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitHubTokensSyncResponse,
    TaskBoardGitIdentityDefaultsResponse, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeConfigResponse, TaskBoardGitRuntimeKeyMaterialSyncRequest,
    TaskBoardGitRuntimeKeyMaterialSyncResponse, TaskBoardGitRuntimeSecretHandoffAckRequest,
    TaskBoardGitRuntimeSecretHandoffAckResponse, TaskBoardGitRuntimeSecretHandoffPrepareResponse,
    TaskBoardGitSigningVerifyRequest, TaskBoardGitSigningVerifyResponse,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
    TaskBoardOrchestratorSettingsResponse, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardOrchestratorStatusResponse, TaskBoardTodoistTokenSyncRequest,
    TaskBoardTodoistTokenSyncResponse,
};
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};

use super::super::{DaemonHttpState, require_async_db};
use super::run_blocking;

pub(crate) async fn orchestrator_status(
    state: &DaemonHttpState,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    service::task_board_orchestrator_status_db(require_async_db(
        state,
        "task board orchestrator status",
    )?)
    .await
}

pub(crate) async fn start_orchestrator(
    state: &DaemonHttpState,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    service::start_task_board_orchestrator_db(require_async_db(
        state,
        "task board orchestrator start",
    )?)
    .await
}

pub(crate) async fn stop_orchestrator(
    state: &DaemonHttpState,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    service::stop_task_board_orchestrator_db(require_async_db(
        state,
        "task board orchestrator stop",
    )?)
    .await
}

pub(crate) async fn automation_runs(
    state: &DaemonHttpState,
    request: &TaskBoardAutomationHistoryRequest,
) -> Result<TaskBoardAutomationRunsResponse, CliError> {
    require_async_db(state, "task board automation run history")?
        .task_board_automation_history(request)
        .await
}

pub(crate) async fn automation_run_detail(
    state: &DaemonHttpState,
    run_id: &str,
) -> Result<TaskBoardAutomationRunDetailResponse, CliError> {
    require_async_db(state, "task board automation run detail")?
        .task_board_automation_run_detail(run_id)
        .await?
        .ok_or_else(|| CliErrorKind::path_not_found(format!("automation run '{run_id}'")).into())
}

pub(crate) async fn automation_metrics(
    state: &DaemonHttpState,
) -> Result<TaskBoardAutomationMetricsResponse, CliError> {
    require_async_db(state, "task board automation metrics")?
        .task_board_automation_metrics()
        .await
}

pub(crate) async fn force_cancel_automation(
    state: &DaemonHttpState,
    request: &TaskBoardAutomationForceCancelRequest,
) -> Result<TaskBoardAutomationForceCancelResponse, CliError> {
    service::force_cancel_task_board_automation_db(
        require_async_db(state, "task board automation force cancel")?,
        request,
    )
    .await
}

pub(crate) async fn orchestrator_settings(
    state: &DaemonHttpState,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    service::task_board_orchestrator_settings_db(require_async_db(
        state,
        "task board orchestrator settings",
    )?)
    .await
}

pub(crate) async fn update_orchestrator_settings(
    state: &DaemonHttpState,
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    request.validate_admission_policy().map_err(|error| {
        CliErrorKind::workflow_parse(format!("invalid task-board admission policy: {error}"))
    })?;
    service::update_task_board_orchestrator_settings_db(
        require_async_db(state, "task board orchestrator settings update")?,
        request,
    )
    .await
}

pub(crate) async fn runtime_config(
    state: &DaemonHttpState,
) -> Result<TaskBoardGitRuntimeConfigResponse, CliError> {
    service::task_board_git_runtime_config_db(require_async_db(state, "task board runtime config")?)
        .await
}

pub(crate) async fn update_runtime_config(
    state: &DaemonHttpState,
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfigResponse, CliError> {
    service::update_task_board_git_runtime_config_db(
        require_async_db(state, "task board runtime config update")?,
        request,
    )
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

pub(crate) async fn sync_git_runtime_key_material(
    request: &TaskBoardGitRuntimeKeyMaterialSyncRequest,
) -> Result<TaskBoardGitRuntimeKeyMaterialSyncResponse, CliError> {
    let request = request.clone();
    run_blocking("Git runtime key-material sync", move || {
        service::sync_task_board_git_runtime_key_material(&request)
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
    state: &DaemonHttpState,
    request: &TaskBoardGitSigningVerifyRequest,
) -> Result<TaskBoardGitSigningVerifyResponse, CliError> {
    service::verify_task_board_git_signing_db(
        require_async_db(state, "task board git signing verify")?,
        request,
    )
    .await
}

pub(crate) async fn prepare_git_runtime_secret_handoff(
    state: &DaemonHttpState,
) -> Result<TaskBoardGitRuntimeSecretHandoffPrepareResponse, CliError> {
    service::prepare_task_board_git_runtime_secret_handoff(require_async_db(
        state,
        "task board git runtime secret handoff prepare",
    )?)
    .await
}

pub(crate) async fn acknowledge_git_runtime_secret_handoff(
    state: &DaemonHttpState,
    request: &TaskBoardGitRuntimeSecretHandoffAckRequest,
) -> Result<TaskBoardGitRuntimeSecretHandoffAckResponse, CliError> {
    service::acknowledge_task_board_git_runtime_secret_handoff(
        require_async_db(
            state,
            "task board git runtime secret handoff acknowledgement",
        )?,
        request,
    )
    .await
}
