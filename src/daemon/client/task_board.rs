use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::daemon::protocol::{
    TASK_BOARD_STORAGE_DATABASE, TaskBoardAuditRequest, TaskBoardAuditResponse,
    TaskBoardCapabilitiesResponse, TaskBoardCatalogRequest, TaskBoardCreateItemRequest,
    TaskBoardDispatchRequest, TaskBoardDispatchResponse, TaskBoardEvaluateRequest,
    TaskBoardEvaluationResponse, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeConfigResponse, TaskBoardHostListResponse, TaskBoardHostLocalResponse,
    TaskBoardHostSetProjectTypesRequest, TaskBoardHostSetProjectTypesResponse,
    TaskBoardListItemsRequest, TaskBoardListItemsResponse, TaskBoardMachinesResponse,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorRunOnceResponse,
    TaskBoardOrchestratorSettingsResponse, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardOrchestratorStatusResponse, TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest,
    TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse,
    TaskBoardProjectsResponse, TaskBoardSyncRequest, TaskBoardSyncResponse,
    TaskBoardTodoistTokenSyncRequest, TaskBoardTodoistTokenSyncResponse,
    TaskBoardUpdateItemRequest, http_paths,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

use super::DaemonClient;

#[expect(
    clippy::missing_errors_doc,
    reason = "all methods forward to daemon HTTP and return CliError on failure"
)]
impl DaemonClient {
    pub fn require_database_task_board(&self) -> Result<i64, CliError> {
        let capability = self
            .get_optional::<TaskBoardCapabilitiesResponse>(
                http_paths::TASK_BOARD_CAPABILITIES,
                &[],
            )?
            .ok_or_else(task_board_upgrade_required)?;
        if capability.storage != TASK_BOARD_STORAGE_DATABASE {
            return Err(task_board_upgrade_required());
        }
        Ok(capability.revision)
    }

    pub fn create_task_board_item(
        &self,
        request: &TaskBoardCreateItemRequest,
    ) -> Result<TaskBoardItem, CliError> {
        self.post(http_paths::TASK_BOARD_ITEMS, request)
    }

    pub fn list_task_board_items(
        &self,
        request: &TaskBoardListItemsRequest,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let response: TaskBoardListItemsResponse =
            self.get_task_board_with_status(http_paths::TASK_BOARD_ITEMS, request.status)?;
        Ok(response.items)
    }

    pub fn get_task_board_item(&self, item_id: &str) -> Result<TaskBoardItem, CliError> {
        self.get(&item_path(item_id))
    }

    pub fn update_task_board_item(
        &self,
        item_id: &str,
        request: &TaskBoardUpdateItemRequest,
    ) -> Result<TaskBoardItem, CliError> {
        self.put(&item_path(item_id), request)
    }

    pub fn delete_task_board_item(&self, item_id: &str) -> Result<TaskBoardItem, CliError> {
        self.delete(&item_path(item_id))
    }

    pub fn begin_task_board_planning(
        &self,
        request: &TaskBoardPlanBeginRequest,
    ) -> Result<TaskBoardPlanningResponse, CliError> {
        self.post(&item_action_path(&request.id, "planning/begin"), request)
    }

    pub fn submit_task_board_plan(
        &self,
        request: &TaskBoardPlanSubmitRequest,
    ) -> Result<TaskBoardPlanningResponse, CliError> {
        self.post(&item_action_path(&request.id, "planning/submit"), request)
    }

    pub fn approve_task_board_plan(
        &self,
        request: &TaskBoardPlanApproveRequest,
    ) -> Result<TaskBoardPlanningResponse, CliError> {
        self.post(&item_action_path(&request.id, "planning/approve"), request)
    }

    pub fn revoke_task_board_plan(
        &self,
        request: &TaskBoardPlanRevokeRequest,
    ) -> Result<TaskBoardPlanningResponse, CliError> {
        self.post(&item_action_path(&request.id, "planning/revoke"), request)
    }

    pub fn sync_task_board(
        &self,
        request: &TaskBoardSyncRequest,
    ) -> Result<TaskBoardSyncResponse, CliError> {
        self.post(http_paths::TASK_BOARD_SYNC, request)
    }

    pub fn dispatch_task_board(
        &self,
        request: &TaskBoardDispatchRequest,
    ) -> Result<TaskBoardDispatchResponse, CliError> {
        self.post(http_paths::TASK_BOARD_DISPATCH, request)
    }

    pub fn evaluate_task_board(
        &self,
        request: &TaskBoardEvaluateRequest,
    ) -> Result<TaskBoardEvaluationResponse, CliError> {
        self.post(http_paths::TASK_BOARD_EVALUATE, request)
    }

    pub fn audit_task_board(
        &self,
        request: &TaskBoardAuditRequest,
    ) -> Result<TaskBoardAuditResponse, CliError> {
        self.get_task_board_with_status(http_paths::TASK_BOARD_AUDIT, request.status)
    }

    pub fn task_board_projects(
        &self,
        request: &TaskBoardCatalogRequest,
    ) -> Result<TaskBoardProjectsResponse, CliError> {
        self.get_task_board_with_status(http_paths::TASK_BOARD_PROJECTS, request.status)
    }

    pub fn task_board_machines(
        &self,
        request: &TaskBoardCatalogRequest,
    ) -> Result<TaskBoardMachinesResponse, CliError> {
        self.get_task_board_with_status(http_paths::TASK_BOARD_MACHINES, request.status)
    }

    pub fn task_board_host_local(&self) -> Result<TaskBoardHostLocalResponse, CliError> {
        self.get(http_paths::TASK_BOARD_HOST_LOCAL)
    }

    pub fn task_board_host_list(&self) -> Result<TaskBoardHostListResponse, CliError> {
        self.get(http_paths::TASK_BOARD_HOST_LIST)
    }

    pub fn set_task_board_host_project_types(
        &self,
        request: &TaskBoardHostSetProjectTypesRequest,
    ) -> Result<TaskBoardHostSetProjectTypesResponse, CliError> {
        self.put(http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES, request)
    }

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

    pub fn sync_task_board_todoist_token(
        &self,
        request: &TaskBoardTodoistTokenSyncRequest,
    ) -> Result<TaskBoardTodoistTokenSyncResponse, CliError> {
        self.put(http_paths::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN, request)
    }

    fn get_task_board_with_status<Res: DeserializeOwned>(
        &self,
        path: &str,
        status: Option<TaskBoardStatus>,
    ) -> Result<Res, CliError> {
        let Some(status) = status else {
            return self.get(path);
        };
        let status = task_board_status_label(status)?;
        self.get_with_query(path, &[("status", status.as_str())])
    }
}

fn item_path(item_id: &str) -> String {
    http_paths::TASK_BOARD_ITEM.replace("{item_id}", item_id)
}

fn item_action_path(item_id: &str, action: &str) -> String {
    format!("{}/{action}", item_path(item_id))
}

fn task_board_status_label(status: TaskBoardStatus) -> Result<String, CliError> {
    serde_json::to_value(status)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| CliErrorKind::workflow_serialize("task-board status is not a string").into())
}

fn task_board_upgrade_required() -> CliError {
    CliErrorKind::workflow_io(
        "the running daemon does not provide database-backed Task Board storage; upgrade and restart the daemon",
    )
    .into()
}
