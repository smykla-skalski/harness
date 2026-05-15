use std::time::Instant;

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCatalogRequest, TaskBoardCreateItemRequest,
    TaskBoardDeleteItemRequest, TaskBoardDispatchRequest, TaskBoardEvaluateRequest,
    TaskBoardGetItemRequest, TaskBoardHostSetProjectTypesRequest, TaskBoardListItemsRequest,
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest, TaskBoardSyncRequest, TaskBoardUpdateItemRequest, http_paths,
};
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::TaskBoardStatus;

use super::super::DaemonHttpState;
use super::super::auth::{authorize_control_request, require_auth};
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
    /// Accepted for forward compatibility with the upcoming binding-trait
    /// override (Unit 7); currently ignored — the route always attributes
    /// revocation to the control plane.
    #[serde(default)]
    #[expect(dead_code)]
    pub actor: Option<String>,
}

macro_rules! authenticated_parts {
    ($headers:expr, $state:expr) => {{
        match authenticated_request(&$headers, &$state) {
            Ok(parts) => parts,
            Err(response) => return *response,
        }
    }};
}

macro_rules! authorized_control_parts {
    ($headers:expr, $state:expr, $request:expr) => {{
        let start = Instant::now();
        let request_id = extract_request_id(&$headers);
        if let Err(response) = authorize_control_request(&$headers, &$state, &mut $request) {
            return *response;
        }
        (start, request_id)
    }};
}

pub(super) async fn post_task_board_item(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardCreateItemRequest>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ITEMS,
        &request_id,
        start,
        task_board_route_executor::create_item(&request),
    )
}

pub(super) async fn get_task_board_items(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    let request = TaskBoardListItemsRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEMS,
        &request_id,
        start,
        task_board_route_executor::list_items(&request),
    )
}

pub(super) async fn get_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        task_board_route_executor::get_item(&TaskBoardGetItemRequest { id: item_id }),
    )
}

pub(super) async fn put_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardUpdateItemRequest>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        task_board_route_executor::update_item(&item_id, &request),
    )
}

pub(super) async fn delete_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    let request = TaskBoardDeleteItemRequest { id: item_id };
    timed_json(
        "DELETE",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        task_board_route_executor::delete_item(&request),
    )
}

pub(super) async fn post_task_board_plan_begin(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    let request = TaskBoardPlanBeginRequest { id: item_id };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_PLAN_BEGIN,
        &request_id,
        start,
        task_board_route_executor::begin_planning(&request),
    )
}

pub(super) async fn post_task_board_plan_submit(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(body): Json<TaskBoardPlanSubmitBody>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    let request = TaskBoardPlanSubmitRequest {
        id: item_id,
        summary: body.summary,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_PLAN_SUBMIT,
        &request_id,
        start,
        task_board_route_executor::submit_plan(&request),
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
    let (start, request_id) = authorized_control_parts!(headers, state, request);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_PLAN_APPROVE,
        &request_id,
        start,
        task_board_route_executor::approve_plan(&request),
    )
}

pub(super) async fn post_task_board_plan_revoke(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    _body: Option<Json<TaskBoardPlanRevokeBody>>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    // Unit 7 will replace this manual override with the binding-trait impl;
    // for now mirror the existing `run_once` pattern so audit logs always
    // attribute the mutation to the control plane (the caller-supplied
    // `actor` in the body is intentionally discarded).
    let request = TaskBoardPlanRevokeRequest {
        id: item_id,
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_PLAN_REVOKE,
        &request_id,
        start,
        task_board_route_executor::revoke_plan(&request),
    )
}

pub(super) async fn post_task_board_sync(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardSyncRequest>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_SYNC,
        &request_id,
        start,
        task_board_route_executor::sync(&request).await,
    )
}

pub(super) async fn post_task_board_dispatch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardDispatchRequest>,
) -> Response {
    let (start, request_id) = authorized_control_parts!(headers, state, request);
    let result = task_board_route_executor::dispatch(&state, request).await;
    timed_json(
        "POST",
        http_paths::TASK_BOARD_DISPATCH,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_board_evaluate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardEvaluateRequest>,
) -> Response {
    let (start, request_id) = authorized_control_parts!(headers, state, request);
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
    let (start, request_id) = authenticated_parts!(headers, state);
    let request = TaskBoardAuditRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_AUDIT,
        &request_id,
        start,
        task_board_route_executor::audit(&request),
    )
}

pub(super) async fn get_task_board_projects(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    let request = TaskBoardCatalogRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_PROJECTS,
        &request_id,
        start,
        task_board_route_executor::projects(&request),
    )
}

pub(super) async fn get_task_board_machines(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    let request = TaskBoardCatalogRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_MACHINES,
        &request_id,
        start,
        task_board_route_executor::machines(&request),
    )
}

pub(super) async fn get_task_board_host_local(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_HOST_LOCAL,
        &request_id,
        start,
        task_board_route_executor::host_local(),
    )
}

pub(super) async fn get_task_board_host_list(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_HOST_LIST,
        &request_id,
        start,
        task_board_route_executor::host_list(),
    )
}

pub(super) async fn put_task_board_host_set_project_types(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardHostSetProjectTypesRequest>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES,
        &request_id,
        start,
        task_board_route_executor::host_set_project_types(&request),
    )
}

fn authenticated_request(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<(Instant, String), Box<Response>> {
    let start = Instant::now();
    let request_id = extract_request_id(headers);
    require_auth(headers, state)?;
    Ok((start, request_id))
}
