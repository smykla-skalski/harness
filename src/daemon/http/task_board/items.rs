use std::time::Instant;

use axum::Json;
use axum::extract::{Path, Query, RawQuery, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::{
    ControlPlaneActorRequest, TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest,
    TaskBoardGetItemRequest, TaskBoardListItemsRequest, TaskBoardPlanApproveRequest,
    TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest,
    TaskBoardUpdateItemRequest, http_paths,
};
use crate::daemon::remote_task_board::{TaskBoardReadListResponse, project_task_board_item};
use crate::daemon::remote_viewer::is_remote_viewer;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    AgentMode, TASK_BOARD_LIST_MAX_CURSOR_CHARS, TASK_BOARD_LIST_MAX_LIMIT,
    TASK_BOARD_LIST_MAX_QUERY_CHARS, TaskBoardPriority, TaskBoardStatus,
};

use super::super::DaemonHttpState;
use super::super::auth::{authenticated_remote_client, authorize_control_request, require_auth};
use super::super::response::{extract_request_id, timed_json};
use super::super::task_board_route_executor;
use super::super::openapi::DaemonErrorBody;
use crate::daemon::protocol::{
    TASK_BOARD_LIST_INVALID_PARAMS, TaskBoardCapabilitiesResponse, TaskBoardListItemsResponse,
    TaskBoardPlanningResponse,
};
use crate::task_board::TaskBoardItem;

/// Status-only query string, shared by the board's summary reads.
#[derive(Debug, Clone, Default, Deserialize)]
#[derive(utoipa::IntoParams)]
#[into_params(parameter_in = Query)]
pub(super) struct TaskBoardStatusQuery {
    pub status: Option<TaskBoardStatus>,
}

/// Query string for `GET /v1/task-board/items`.
///
/// `tag` repeats instead of taking a list, so it is collected from the raw
/// query string: `serde_urlencoded`, which backs axum's `Query`, cannot
/// deserialize a repeated key into a `Vec`.
#[derive(Debug, Clone, Default, Deserialize)]
#[derive(utoipa::IntoParams)]
#[into_params(parameter_in = Query)]
pub(super) struct TaskBoardListQuery {
    pub status: Option<TaskBoardStatus>,
    pub priority: Option<TaskBoardPriority>,
    pub agent_mode: Option<AgentMode>,
    pub project_id: Option<String>,
    /// Case-insensitive substring over title, body, and tags.
    #[param(max_length = 512)]
    pub query: Option<String>,
    /// Page size, `1..=500`; defaults to 200.
    #[param(minimum = 1, maximum = 500)]
    pub limit: Option<u32>,
    /// `next_cursor` from the previous page.
    #[param(max_length = 512)]
    pub cursor: Option<String>,
}

// `utoipa` takes only literals for these bounds, so the schema would silently
// stop describing what the daemon enforces if either constant moved.
const _: () = assert!(TASK_BOARD_LIST_MAX_LIMIT == 500);
const _: () = assert!(TASK_BOARD_LIST_MAX_QUERY_CHARS == 512);
const _: () = assert!(TASK_BOARD_LIST_MAX_CURSOR_CHARS == 512);

#[derive(Debug, Clone, Deserialize)]
#[derive(utoipa::ToSchema)]
pub(super) struct TaskBoardPlanSubmitBody {
    pub summary: String,
}

#[derive(Debug, Clone, Deserialize)]
#[derive(utoipa::ToSchema)]
pub(super) struct TaskBoardPlanApproveBody {
    pub approved_by: String,
    pub approved_at: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[derive(utoipa::ToSchema)]
pub(super) struct TaskBoardPlanRevokeBody {
    #[serde(default)]
    pub actor: Option<String>,
}

#[utoipa::path(
    post,
    path = "/v1/task-board/items",
    tag = "task-board",
    description = "Create a new task-board item and return it as persisted",
    request_body = TaskBoardCreateItemRequest,
    responses(
        (status = 200, description = "The created task-board item", body = TaskBoardItem),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/task-board/capabilities",
    tag = "task-board",
    description = "Return the task-board storage backend, current revision, and instance identifier",
    responses(
        (status = 200, description = "Task-board capability descriptor", body = TaskBoardCapabilitiesResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/task-board/items",
    tag = "task-board",
    description = "List one bounded page of task-board items matching the requested facets and text, with progress rollups over the whole live board. Remote viewers receive a projected response with viewer-restricted fields removed, and their facets and text match that same projection",
    params(
        TaskBoardListQuery,
        ("tag" = Option<Vec<String>>, Query, description = "Repeatable; an item must carry every requested tag"),
    ),
    responses(
        (status = 200, description = "One page of task-board items with progress rollups and the next-page cursor", body = TaskBoardListItemsResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn get_task_board_items(
    Query(query): Query<TaskBoardListQuery>,
    RawQuery(raw_query): RawQuery,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let Some(tags) = repeated_query_values(raw_query.as_deref(), "tag") else {
        return timed_json(
            "GET",
            http_paths::TASK_BOARD_ITEMS,
            &request_id,
            start,
            Err::<TaskBoardReadListResponse, _>(CliError::from(CliErrorKind::workflow_io(
                TASK_BOARD_LIST_INVALID_PARAMS,
            ))),
        );
    };
    let request = TaskBoardListItemsRequest {
        status: query.status,
        priority: query.priority,
        agent_mode: query.agent_mode,
        project_id: query.project_id,
        tags,
        query: query.query,
        limit: query.limit,
        cursor: query.cursor,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEMS,
        &request_id,
        start,
        task_board_route_executor::list_items(&state, &request, viewer).await,
    )
}

/// Collect every value a repeated query key carries, in request order.
///
/// `None` means the query string itself would not decode, which the caller
/// turns into the same invalid-params refusal the rest of the selection uses:
/// dropping the repeated values instead would answer a malformed request as
/// though it had asked for no tags at all.
fn repeated_query_values(raw_query: Option<&str>, key: &str) -> Option<Vec<String>> {
    let Some(raw_query) = raw_query else {
        return Some(Vec::new());
    };
    Some(
        serde_urlencoded::from_str::<Vec<(String, String)>>(raw_query)
            .ok()?
            .into_iter()
            .filter(|(name, _)| name == key)
            .map(|(_, value)| value)
            .collect(),
    )
}

#[utoipa::path(
    get,
    path = "/v1/task-board/items/{item_id}",
    tag = "task-board",
    description = "Return a single task-board item by id. Remote viewers receive a projected response with viewer-restricted fields removed",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    responses(
        (status = 200, description = "The requested task-board item", body = TaskBoardItem),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    put,
    path = "/v1/task-board/items/{item_id}",
    tag = "task-board",
    description = "Update an existing task-board item's editable fields and return it as persisted",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    request_body = TaskBoardUpdateItemRequest,
    responses(
        (status = 200, description = "The updated task-board item", body = TaskBoardItem),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    delete,
    path = "/v1/task-board/items/{item_id}",
    tag = "task-board",
    description = "Delete a task-board item by tombstoning it rather than removing it outright, and return the tombstoned item",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    responses(
        (status = 200, description = "The deleted (tombstoned) task-board item", body = TaskBoardItem),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/task-board/items/{item_id}/planning/begin",
    tag = "task-board",
    description = "Transition a task-board item into the planning phase and return the resulting planning state",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    responses(
        (status = 200, description = "Planning transition after entering planning", body = TaskBoardPlanningResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/task-board/items/{item_id}/planning/submit",
    tag = "task-board",
    description = "Submit a plan summary for a task-board item and return the resulting planning state",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    request_body = TaskBoardPlanSubmitBody,
    responses(
        (status = 200, description = "Planning transition after submitting a plan", body = TaskBoardPlanningResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/task-board/items/{item_id}/planning/approve",
    tag = "task-board",
    description = "Approve the submitted plan for a task-board item and return the resulting planning state. Requires a control-plane actor bound to the request",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    request_body = TaskBoardPlanApproveBody,
    responses(
        (status = 200, description = "Planning transition after approving the plan", body = TaskBoardPlanningResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    post,
    path = "/v1/task-board/items/{item_id}/planning/revoke",
    tag = "task-board",
    description = "Revoke a previously approved plan for a task-board item and return the resulting planning state. Requires a control-plane actor bound to the request",
    params(("item_id" = String, Path, description = "Task-board item identifier")),
    request_body(content = TaskBoardPlanRevokeBody, description = "Optional actor override; the body may be omitted"),
    responses(
        (status = 200, description = "Planning transition after revoking plan approval", body = TaskBoardPlanningResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
