use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardAuditResponse, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardListItemsRequest, TaskBoardListItemsResponse, TaskBoardMachinesResponse,
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanSubmitRequest,
    TaskBoardPlanningResponse, TaskBoardProjectsResponse, TaskBoardSyncRequest,
    TaskBoardSyncResponse, TaskBoardUpdateItemRequest,
};
use crate::daemon::service;
use crate::errors::CliError;
use crate::task_board::TaskBoardItem;

pub(crate) fn create_item(request: &TaskBoardCreateItemRequest) -> Result<TaskBoardItem, CliError> {
    service::create_task_board_item(request)
}

pub(crate) fn list_items(
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    service::list_task_board_items(request)
}

pub(crate) fn get_item(request: &TaskBoardGetItemRequest) -> Result<TaskBoardItem, CliError> {
    service::get_task_board_item(request)
}

pub(crate) fn update_item(
    id: &str,
    request: &TaskBoardUpdateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    service::update_task_board_item(id, request)
}

pub(crate) fn delete_item(request: &TaskBoardDeleteItemRequest) -> Result<TaskBoardItem, CliError> {
    service::delete_task_board_item(request)
}

pub(crate) fn begin_planning(
    request: &TaskBoardPlanBeginRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    service::begin_task_board_planning(request)
}

pub(crate) fn submit_plan(
    request: &TaskBoardPlanSubmitRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    service::submit_task_board_plan(request)
}

pub(crate) fn approve_plan(
    request: &TaskBoardPlanApproveRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    service::approve_task_board_plan(request)
}

pub(crate) async fn sync(
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    service::sync_task_board_async(request).await
}

pub(crate) fn audit(request: &TaskBoardAuditRequest) -> Result<TaskBoardAuditResponse, CliError> {
    service::audit_task_board(request)
}

pub(crate) fn projects(
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardProjectsResponse, CliError> {
    service::list_task_board_projects(request)
}

pub(crate) fn machines(
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardMachinesResponse, CliError> {
    service::list_task_board_machines(request)
}
