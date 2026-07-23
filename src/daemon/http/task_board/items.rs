use std::time::Instant;

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::{
    ControlPlaneActorRequest, TaskBoardAuditRequest, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardDispatchDeliverRequest,
    TaskBoardDispatchPickRequest, TaskBoardDispatchRequest, TaskBoardEvaluateRequest,
    TaskBoardGetItemRequest, TaskBoardHostSetProjectTypesRequest, TaskBoardListItemsRequest,
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest, TaskBoardSyncRequest, TaskBoardUpdateItemRequest, http_paths,
};
use crate::daemon::remote_task_board::{project_task_board_item, project_task_board_list};
use crate::daemon::remote_viewer::is_remote_viewer;
use crate::task_board::TaskBoardStatus;

use super::super::DaemonHttpState;
use super::super::auth::{authenticated_remote_client, authorize_control_request, require_auth};
use super::super::response::{extract_request_id, timed_json};
use super::super::task_board_route_executor;

#[derive(Debug, Clone, Default, Deserialize)]
pub(super) struct TaskBoardListQuery {
    pub status: Option<TaskBoardStatus>,
}

#[derive(Debug, Clone, Deserialize)]
pub(super) struct TaskBoardPlanSubmitBody {
    pub summary: String,
}

#[derive(Debug, Clone, Deserialize)]
pub(super) struct TaskBoardPlanApproveBody {
    pub approved_by: String,
    pub approved_at: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub(super) struct TaskBoardPlanRevokeBody {
    #[serde(default)]
    pub actor: Option<String>,
}

pub(super) async fn post_task_board_item(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardCreateItemRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ITEMS,
        &request_id,
        start,
        task_board_route_executor::create_item(&state, &request).await,
    )
}

pub(super) async fn get_task_board_capabilities(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_CAPABILITIES,
        &request_id,
        start,
        task_board_route_executor::capabilities(&state).await,
    )
}

pub(super) async fn get_task_board_items(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let request = TaskBoardListItemsRequest {
        status: query.status,
    };
    let result = task_board_route_executor::list_items(&state, &request)
        .await
        .map(|response| project_task_board_list(response, viewer));
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEMS,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result =
        task_board_route_executor::get_item(&state, &TaskBoardGetItemRequest { id: item_id })
            .await
            .map(|item| project_task_board_item(item, viewer));
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn put_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardUpdateItemRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        task_board_route_executor::update_item(&state, &item_id, &request).await,
    )
}

pub(super) async fn delete_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let request = TaskBoardDeleteItemRequest { id: item_id };
    timed_json(
        "DELETE",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        task_board_route_executor::delete_item(&state, &request).await,
    )
}

pub(super) async fn post_task_board_plan_begin(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let request = TaskBoardPlanBeginRequest { id: item_id };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_PLAN_BEGIN,
        &request_id,
        start,
        task_board_route_executor::begin_planning(&state, &request).await,
    )
}

pub(super) async fn post_task_board_plan_submit(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(body): Json<TaskBoardPlanSubmitBody>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let request = TaskBoardPlanSubmitRequest {
        id: item_id,
        summary: body.summary,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_PLAN_SUBMIT,
        &request_id,
        start,
        task_board_route_executor::submit_plan(&state, &request).await,
    )
}

pub(super) async fn post_task_board_plan_approve(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(body): Json<TaskBoardPlanApproveBody>,
) -> Response {
    let mut request = TaskBoardPlanApproveRequest {
        id: item_id,
        approved_by: body.approved_by,
        approved_at: body.approved_at,
    };
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_PLAN_APPROVE,
        &request_id,
        start,
        task_board_route_executor::approve_plan(&state, &request).await,
    )
}

pub(super) async fn post_task_board_plan_revoke(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    body: Option<Json<TaskBoardPlanRevokeBody>>,
) -> Response {
    let mut request = TaskBoardPlanRevokeRequest {
        id: item_id,
        actor: body.and_then(|Json(body)| body.actor),
    };
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_PLAN_REVOKE,
        &request_id,
        start,
        task_board_route_executor::revoke_plan(&state, &request).await,
    )
}

pub(super) async fn post_task_board_sync(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardSyncRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_SYNC,
        &request_id,
        start,
        task_board_route_executor::sync(&state, &request).await,
    )
}

pub(super) async fn post_task_board_dispatch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardDispatchRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result = Box::pin(task_board_route_executor::dispatch(&state, request)).await;
    timed_json(
        "POST",
        http_paths::TASK_BOARD_DISPATCH,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_board_dispatch_deliver(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardDispatchDeliverRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_DISPATCH_DELIVER,
        &request_id,
        start,
        task_board_route_executor::deliver(&state, &request).await,
    )
}

pub(super) async fn post_task_board_dispatch_pick(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    _body: Option<Json<TaskBoardDispatchPickRequest>>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_DISPATCH_PICK,
        &request_id,
        start,
        task_board_route_executor::pick(&state).await,
    )
}

pub(super) async fn post_task_board_evaluate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardEvaluateRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result = task_board_route_executor::evaluate(&state, request).await;
    timed_json(
        "POST",
        http_paths::TASK_BOARD_EVALUATE,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_task_board_audit(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let request = TaskBoardAuditRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_AUDIT,
        &request_id,
        start,
        task_board_route_executor::audit(&state, &request).await,
    )
}

pub(super) async fn get_task_board_projects(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let request = TaskBoardCatalogRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_PROJECTS,
        &request_id,
        start,
        task_board_route_executor::projects(&state, &request).await,
    )
}

pub(super) async fn get_task_board_machines(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let request = TaskBoardCatalogRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_MACHINES,
        &request_id,
        start,
        task_board_route_executor::machines(&state, &request).await,
    )
}

pub(super) async fn get_task_board_host_local(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_HOST_LOCAL,
        &request_id,
        start,
        task_board_route_executor::host_local(&state).await,
    )
}

pub(super) async fn get_task_board_host_list(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_HOST_LIST,
        &request_id,
        start,
        task_board_route_executor::host_list(&state).await,
    )
}

pub(super) async fn put_task_board_host_set_project_types(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardHostSetProjectTypesRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES,
        &request_id,
        start,
        task_board_route_executor::host_set_project_types(&state, &request).await,
    )
}

pub(in super::super) fn authenticated_request(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<(Instant, String), Box<Response>> {
    let start = Instant::now();
    let request_id = extract_request_id(headers);
    require_auth(headers, state)?;
    Ok((start, request_id))
}

pub(in super::super) fn authenticated_task_board_read(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<(Instant, String, bool), Box<Response>> {
    let start = Instant::now();
    let request_id = extract_request_id(headers);
    let client = authenticated_remote_client(headers, state)?;
    Ok((start, request_id, is_remote_viewer(client.as_ref())))
}

pub(in super::super) fn authorized_control_request_parts<T: ControlPlaneActorRequest>(
    headers: &HeaderMap,
    state: &DaemonHttpState,
    request: &mut T,
) -> Result<(Instant, String), Box<Response>> {
    let start = Instant::now();
    let request_id = extract_request_id(headers);
    authorize_control_request(headers, state, request)?;
    Ok((start, request_id))
}
