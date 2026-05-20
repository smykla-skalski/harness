use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardAuditResponse, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardHostListResponse, TaskBoardHostLocalResponse, TaskBoardHostSetProjectTypesRequest,
    TaskBoardHostSetProjectTypesResponse, TaskBoardListItemsRequest, TaskBoardListItemsResponse,
    TaskBoardMachinesResponse, TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest,
    TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse,
    TaskBoardProjectsResponse, TaskBoardSyncRequest, TaskBoardSyncResponse,
    TaskBoardUpdateItemRequest,
};
use crate::daemon::service;
use crate::errors::CliError;
use crate::task_board::TaskBoardItem;

use super::run_blocking;

pub(crate) async fn create_item(
    request: &TaskBoardCreateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    let request = request.clone();
    run_blocking("create item", move || {
        service::create_task_board_item(&request)
    })
    .await
}

pub(crate) async fn list_items(
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    let request = request.clone();
    run_blocking("list items", move || {
        service::list_task_board_items(&request)
    })
    .await
}

pub(crate) async fn get_item(request: &TaskBoardGetItemRequest) -> Result<TaskBoardItem, CliError> {
    let request = request.clone();
    run_blocking("get item", move || service::get_task_board_item(&request)).await
}

pub(crate) async fn update_item(
    id: &str,
    request: &TaskBoardUpdateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    let id = id.to_string();
    let request = request.clone();
    run_blocking("update item", move || {
        service::update_task_board_item(&id, &request)
    })
    .await
}

pub(crate) async fn delete_item(
    request: &TaskBoardDeleteItemRequest,
) -> Result<TaskBoardItem, CliError> {
    let request = request.clone();
    run_blocking("delete item", move || {
        service::delete_task_board_item(&request)
    })
    .await
}

pub(crate) async fn begin_planning(
    request: &TaskBoardPlanBeginRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let request = request.clone();
    run_blocking("begin planning", move || {
        service::begin_task_board_planning(&request)
    })
    .await
}

pub(crate) async fn submit_plan(
    request: &TaskBoardPlanSubmitRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let request = request.clone();
    run_blocking("submit plan", move || {
        service::submit_task_board_plan(&request)
    })
    .await
}

pub(crate) async fn approve_plan(
    request: &TaskBoardPlanApproveRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let request = request.clone();
    run_blocking("approve plan", move || {
        service::approve_task_board_plan(&request)
    })
    .await
}

pub(crate) async fn revoke_plan(
    request: &TaskBoardPlanRevokeRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let request = request.clone();
    run_blocking("revoke plan", move || {
        service::revoke_task_board_plan(&request)
    })
    .await
}

pub(crate) async fn sync(
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    service::sync_task_board_async(request).await
}

pub(crate) async fn audit(
    request: &TaskBoardAuditRequest,
) -> Result<TaskBoardAuditResponse, CliError> {
    let request = request.clone();
    run_blocking("audit", move || service::audit_task_board(&request)).await
}

pub(crate) async fn projects(
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardProjectsResponse, CliError> {
    let request = request.clone();
    run_blocking("projects", move || {
        service::list_task_board_projects(&request)
    })
    .await
}

pub(crate) async fn machines(
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardMachinesResponse, CliError> {
    let request = request.clone();
    run_blocking("machines", move || {
        service::list_task_board_machines(&request)
    })
    .await
}

pub(crate) async fn host_local() -> Result<TaskBoardHostLocalResponse, CliError> {
    run_blocking("host local", service::task_board_host_local).await
}

pub(crate) async fn host_list() -> Result<TaskBoardHostListResponse, CliError> {
    run_blocking("host list", service::task_board_host_list).await
}

pub(crate) async fn host_set_project_types(
    request: &TaskBoardHostSetProjectTypesRequest,
) -> Result<TaskBoardHostSetProjectTypesResponse, CliError> {
    let request = request.clone();
    run_blocking("host set project types", move || {
        service::task_board_host_set_project_types(&request)
    })
    .await
}
