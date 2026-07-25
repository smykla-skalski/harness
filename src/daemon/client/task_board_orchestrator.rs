use serde_json::Value;

use crate::daemon::protocol::{
    TaskBoardAutomationHistoryRequest, TaskBoardAutomationMetricsResponse,
    TaskBoardAutomationRunDetailResponse, TaskBoardAutomationRunsResponse,
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitHubTokensSyncResponse, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeConfigResponse, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse, TaskBoardOrchestratorSettingsResponse,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorStatusResponse, http_paths,
};
use crate::errors::CliError;

use super::DaemonClient;

/// Task Board orchestrator/automation client methods, split from
/// `task_board.rs` purely to keep that file under the repo's line cap.
#[expect(
    clippy::missing_errors_doc,
    reason = "all methods forward to daemon HTTP and return CliError on failure"
)]
impl DaemonClient {
    pub fn task_board_orchestrator_status(
        &self,
    ) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
        self.get(http_paths::TASK_BOARD_ORCHESTRATOR_STATUS)
    }

    pub fn start_task_board_orchestrator(
        &self,
    ) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
        self.post(http_paths::TASK_BOARD_ORCHESTRATOR_START, &Value::Null)
    }

    pub fn stop_task_board_orchestrator(
        &self,
    ) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
        self.post(http_paths::TASK_BOARD_ORCHESTRATOR_STOP, &Value::Null)
    }

    pub fn run_task_board_orchestrator_once(
        &self,
        request: &TaskBoardOrchestratorRunOnceRequest,
    ) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
        self.post(http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE, request)
    }

    pub fn task_board_automation_runs(
        &self,
        request: &TaskBoardAutomationHistoryRequest,
    ) -> Result<TaskBoardAutomationRunsResponse, CliError> {
        let limit = request.limit.map(|value| value.to_string());
        let mut query = Vec::with_capacity(2);
        if let Some(value) = limit.as_deref() {
            query.push(("limit", value));
        }
        if let Some(value) = request.before.as_deref() {
            query.push(("before", value));
        }
        self.get_with_query(http_paths::TASK_BOARD_ORCHESTRATOR_RUNS, &query)
    }

    pub fn task_board_automation_run_detail(
        &self,
        run_id: &str,
    ) -> Result<TaskBoardAutomationRunDetailResponse, CliError> {
        self.get(&automation_run_detail_path(run_id))
    }

    pub fn task_board_automation_metrics(
        &self,
    ) -> Result<TaskBoardAutomationMetricsResponse, CliError> {
        self.get(http_paths::TASK_BOARD_ORCHESTRATOR_METRICS)
    }

    pub fn task_board_orchestrator_settings(
        &self,
    ) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
        self.get(http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS)
    }

    pub fn update_task_board_orchestrator_settings(
        &self,
        request: &TaskBoardOrchestratorSettingsUpdateRequest,
    ) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
        self.put(http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS, request)
    }

    pub fn task_board_runtime_config(&self) -> Result<TaskBoardGitRuntimeConfigResponse, CliError> {
        self.get(http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG)
    }

    pub fn update_task_board_runtime_config(
        &self,
        request: &TaskBoardGitRuntimeConfig,
    ) -> Result<TaskBoardGitRuntimeConfigResponse, CliError> {
        self.put(http_paths::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG, request)
    }

    pub fn sync_task_board_github_tokens(
        &self,
        request: &TaskBoardGitHubTokensSyncRequest,
    ) -> Result<TaskBoardGitHubTokensSyncResponse, CliError> {
        self.put(http_paths::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS, request)
    }

}

fn automation_run_detail_path(run_id: &str) -> String {
    let mut base = reqwest::Url::parse("http://localhost/").expect("static URL should parse");
    base.path_segments_mut()
        .expect("static URL should accept path segments")
        .pop_if_empty()
        .push(run_id);
    let encoded_run_id = base.path().trim_start_matches('/');
    http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL.replace("{run_id}", encoded_run_id)
}
