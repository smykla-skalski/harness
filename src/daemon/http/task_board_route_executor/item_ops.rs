use crate::daemon::protocol::{
    TASK_BOARD_STORAGE_DATABASE, TaskBoardAuditRequest, TaskBoardAuditResponse,
    TaskBoardCapabilitiesResponse, TaskBoardCatalogRequest, TaskBoardCreateItemRequest,
    TaskBoardDeleteItemRequest, TaskBoardGetItemRequest, TaskBoardHostListResponse,
    TaskBoardHostLocalResponse, TaskBoardHostSetProjectTypesRequest,
    TaskBoardHostSetProjectTypesResponse, TaskBoardItemPositionMutationResponse,
    TaskBoardItemPositionSnapshot, TaskBoardListItemsRequest, TaskBoardListItemsResponse,
    TaskBoardMachinesResponse, TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest,
    TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse,
    TaskBoardProjectsResponse, TaskBoardResetItemPositionRequest, TaskBoardSetItemPositionRequest,
    TaskBoardSyncRequest, TaskBoardSyncResponse, TaskBoardTriageCurrentResponse,
    TaskBoardTriageHistoryResponse, TaskBoardUpdateItemRequest,
};
use crate::daemon::service;
use crate::errors::CliError;
use crate::task_board::TaskBoardItem;

use super::super::{DaemonHttpState, require_async_db};

pub(crate) async fn capabilities(
    state: &DaemonHttpState,
) -> Result<TaskBoardCapabilitiesResponse, CliError> {
    let db = require_async_db(state, "task board capabilities")?;
    let (revision, instance_id) =
        tokio::try_join!(db.task_board_revision(), db.task_board_instance_id())?;
    Ok(TaskBoardCapabilitiesResponse {
        storage: TASK_BOARD_STORAGE_DATABASE.to_string(),
        revision,
        instance_id,
    })
}

pub(crate) async fn create_item(
    state: &DaemonHttpState,
    request: &TaskBoardCreateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    service::create_task_board_item_db(require_async_db(state, "task board create")?, request).await
}

pub(crate) async fn list_items(
    state: &DaemonHttpState,
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    service::list_task_board_items_db(require_async_db(state, "task board list")?, request).await
}

pub(crate) async fn get_item(
    state: &DaemonHttpState,
    request: &TaskBoardGetItemRequest,
) -> Result<TaskBoardItem, CliError> {
    service::get_task_board_item_db(require_async_db(state, "task board get")?, request).await
}

pub(crate) async fn get_item_position_snapshot(
    state: &DaemonHttpState,
    item_id: &str,
) -> Result<TaskBoardItemPositionSnapshot, CliError> {
    service::get_task_board_item_position_snapshot_db(
        require_async_db(state, "task board position snapshot")?,
        item_id,
    )
    .await
}

pub(crate) async fn set_item_position(
    state: &DaemonHttpState,
    item_id: &str,
    request: &TaskBoardSetItemPositionRequest,
) -> Result<TaskBoardItemPositionMutationResponse, CliError> {
    service::set_task_board_item_position_db(
        require_async_db(state, "task board position set")?,
        item_id,
        request,
    )
    .await
}

pub(crate) async fn reset_item_position(
    state: &DaemonHttpState,
    item_id: &str,
    request: &TaskBoardResetItemPositionRequest,
) -> Result<TaskBoardItemPositionMutationResponse, CliError> {
    service::reset_task_board_item_position_db(
        require_async_db(state, "task board position reset")?,
        item_id,
        request,
    )
    .await
}

pub(crate) async fn get_item_triage_current(
    state: &DaemonHttpState,
    item_id: &str,
) -> Result<TaskBoardTriageCurrentResponse, CliError> {
    service::get_task_board_item_triage_current_db(
        require_async_db(state, "task board triage current")?,
        item_id,
    )
    .await
}

pub(crate) async fn get_item_triage_history(
    state: &DaemonHttpState,
    item_id: &str,
    before_generation: Option<u64>,
    limit: u32,
) -> Result<TaskBoardTriageHistoryResponse, CliError> {
    service::get_task_board_item_triage_history_db(
        require_async_db(state, "task board triage history")?,
        item_id,
        before_generation,
        limit,
    )
    .await
}

pub(crate) async fn update_item(
    state: &DaemonHttpState,
    id: &str,
    request: &TaskBoardUpdateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    service::update_task_board_item_db(require_async_db(state, "task board update")?, id, request)
        .await
}

pub(crate) async fn delete_item(
    state: &DaemonHttpState,
    request: &TaskBoardDeleteItemRequest,
) -> Result<TaskBoardItem, CliError> {
    service::delete_task_board_item_db(require_async_db(state, "task board delete")?, request).await
}

pub(crate) async fn begin_planning(
    state: &DaemonHttpState,
    request: &TaskBoardPlanBeginRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    service::begin_task_board_planning_db(
        require_async_db(state, "task board begin planning")?,
        request,
    )
    .await
}

pub(crate) async fn submit_plan(
    state: &DaemonHttpState,
    request: &TaskBoardPlanSubmitRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    service::submit_task_board_plan_db(require_async_db(state, "task board submit plan")?, request)
        .await
}

pub(crate) async fn approve_plan(
    state: &DaemonHttpState,
    request: &TaskBoardPlanApproveRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    service::approve_task_board_plan_db(
        require_async_db(state, "task board approve plan")?,
        request,
    )
    .await
}

pub(crate) async fn revoke_plan(
    state: &DaemonHttpState,
    request: &TaskBoardPlanRevokeRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    service::revoke_task_board_plan_db(require_async_db(state, "task board revoke plan")?, request)
        .await
}

pub(crate) async fn sync(
    state: &DaemonHttpState,
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    service::sync_task_board_db(require_async_db(state, "task board sync")?, request).await
}

pub(crate) async fn audit(
    state: &DaemonHttpState,
    request: &TaskBoardAuditRequest,
) -> Result<TaskBoardAuditResponse, CliError> {
    service::audit_task_board_db(require_async_db(state, "task board audit")?, request).await
}

pub(crate) async fn projects(
    state: &DaemonHttpState,
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardProjectsResponse, CliError> {
    service::list_task_board_projects_db(require_async_db(state, "task board projects")?, request)
        .await
}

pub(crate) async fn machines(
    state: &DaemonHttpState,
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardMachinesResponse, CliError> {
    service::list_task_board_machines_db(require_async_db(state, "task board machines")?, request)
        .await
}

pub(crate) async fn host_local(
    state: &DaemonHttpState,
) -> Result<TaskBoardHostLocalResponse, CliError> {
    service::task_board_host_local_db(require_async_db(state, "task board local host")?).await
}

pub(crate) async fn host_list(
    state: &DaemonHttpState,
) -> Result<TaskBoardHostListResponse, CliError> {
    service::task_board_host_list_db(require_async_db(state, "task board hosts")?).await
}

pub(crate) async fn host_set_project_types(
    state: &DaemonHttpState,
    request: &TaskBoardHostSetProjectTypesRequest,
) -> Result<TaskBoardHostSetProjectTypesResponse, CliError> {
    service::task_board_host_set_project_types_db(
        require_async_db(state, "task board host project types")?,
        request,
    )
    .await
}
