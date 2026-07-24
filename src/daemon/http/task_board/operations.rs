use axum::Json;
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCatalogRequest, TaskBoardDispatchDeliverRequest,
    TaskBoardDispatchDeliverResponse, TaskBoardDispatchPickRequest, TaskBoardDispatchPickResponse,
    TaskBoardDispatchRequest, TaskBoardEvaluateRequest, TaskBoardHostSetProjectTypesRequest,
    TaskBoardSyncRequest, http_paths,
};
use crate::task_board::{
    DispatchExecutionSummary, Machine, TaskBoardAuditSummary, TaskBoardEvaluationSummary,
    TaskBoardMachineSummary, TaskBoardProjectSummary, TaskBoardSyncSummary,
};

use super::super::DaemonHttpState;
#[cfg(feature = "openapi")]
use super::super::openapi::DaemonErrorBody;
use super::super::response::timed_json;
use super::super::task_board_route_executor;
use super::items::{
    TaskBoardListQuery, authenticated_request, authorized_control_request_parts,
};

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/sync",
    tag = "task-board",
    request_body = TaskBoardSyncRequest,
    responses(
        (status = 200, description = "Per-provider sync summary", body = TaskBoardSyncSummary),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/dispatch",
    tag = "task-board",
    request_body = TaskBoardDispatchRequest,
    responses(
        (status = 200, description = "Dispatch plans, applied tasks, and failures", body = DispatchExecutionSummary),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/dispatch/deliver",
    tag = "task-board",
    request_body = TaskBoardDispatchDeliverRequest,
    responses(
        (status = 200, description = "Delivered dispatch with the optionally started agent", body = TaskBoardDispatchDeliverResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/dispatch/pick",
    tag = "task-board",
    responses(
        (status = 200, description = "The picked dispatch selection, if any is ready", body = TaskBoardDispatchPickResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/evaluate",
    tag = "task-board",
    request_body = TaskBoardEvaluateRequest,
    responses(
        (status = 200, description = "Evaluation records and signal outcomes", body = TaskBoardEvaluationSummary),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/audit",
    tag = "task-board",
    params(TaskBoardListQuery),
    responses(
        (status = 200, description = "Audit summary with per-status counts", body = TaskBoardAuditSummary),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/projects",
    tag = "task-board",
    params(TaskBoardListQuery),
    responses(
        (status = 200, description = "Project summaries derived from the board", body = Vec<TaskBoardProjectSummary>),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/machines",
    tag = "task-board",
    params(TaskBoardListQuery),
    responses(
        (status = 200, description = "Machine summaries derived from the board", body = Vec<TaskBoardMachineSummary>),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/host/local",
    tag = "task-board",
    responses(
        (status = 200, description = "The local execution-host machine record", body = Machine),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/host/list",
    tag = "task-board",
    responses(
        (status = 200, description = "All registered execution-host machine records", body = Vec<Machine>),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    put,
    path = "/v1/task-board/host/project-types",
    tag = "task-board",
    request_body = TaskBoardHostSetProjectTypesRequest,
    responses(
        (status = 200, description = "The updated local execution-host machine record", body = Machine),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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
