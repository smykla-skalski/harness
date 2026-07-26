use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::protocol::{
    TaskBoardAutomationForceCancelRequest, TaskBoardAutomationHistoryRequest,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest, http_paths,
};
use crate::task_board::{
    TaskBoardAutomationHistoryResponse, TaskBoardAutomationMetrics, TaskBoardAutomationRunDetail,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorStatus,
};

use super::DaemonHttpState;
use super::openapi::DaemonErrorBody;
use super::response::timed_json;
use super::task_board::{authenticated_request, authorized_control_request_parts};
use super::task_board_route_executor;
use crate::daemon::protocol::TaskBoardAutomationForceCancelResponse;

/// Wire the orchestrator lifecycle, automation-history, and settings endpoints
/// onto the task-board router. The git-runtime, provider-token, and
/// secret-handoff endpoints live in `task_board_git` so both files stay within
/// the file-length cap.
pub(super) fn merge_orchestrator_routes(
    router: OpenApiRouter<DaemonHttpState>,
) -> OpenApiRouter<DaemonHttpState> {
    router
        .merge(orchestrator_control_routes())
        .merge(orchestrator_automation_routes())
}

fn orchestrator_control_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_task_board_orchestrator_status))
        .routes(routes!(post_task_board_orchestrator_start))
        .routes(routes!(post_task_board_orchestrator_stop))
        .routes(routes!(post_task_board_orchestrator_run_once))
        .routes(routes!(
            get_task_board_orchestrator_settings,
            put_task_board_orchestrator_settings
        ))
}

fn orchestrator_automation_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_task_board_automation_runs))
        .routes(routes!(get_task_board_automation_run_detail))
        .routes(routes!(get_task_board_automation_metrics))
        .routes(routes!(post_task_board_automation_force_cancel))
}

#[utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/status",
    tag = "task-board",
    description = "Read the task-board orchestrator's current status, including whether its background automation loop is running and the outcome of the most recent run",
    responses(
        (status = 200, description = "Current orchestrator status", body = TaskBoardOrchestratorStatus),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn get_task_board_orchestrator_status(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
        &request_id,
        start,
        task_board_route_executor::orchestrator_status(&state).await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board/orchestrator/start",
    tag = "task-board",
    description = "Start the task-board orchestrator's background automation loop and return its status immediately after starting",
    responses(
        (status = 200, description = "Orchestrator status after starting the loop", body = TaskBoardOrchestratorStatus),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn post_task_board_orchestrator_start(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_START,
        &request_id,
        start,
        task_board_route_executor::start_orchestrator(&state).await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board/orchestrator/stop",
    tag = "task-board",
    description = "Stop the task-board orchestrator's background automation loop and return its status immediately after stopping",
    responses(
        (status = 200, description = "Orchestrator status after stopping the loop", body = TaskBoardOrchestratorStatus),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn post_task_board_orchestrator_stop(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
        &request_id,
        start,
        task_board_route_executor::stop_orchestrator(&state).await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board/orchestrator/run-once",
    tag = "task-board",
    description = "Run a single manual tick of the task-board orchestrator loop (evaluate, dispatch, and start eligible workers) outside its regular schedule. The request's actor attribution is rebound to the authenticated control-plane principal, overriding any client-supplied value",
    request_body = TaskBoardOrchestratorRunOnceRequest,
    responses(
        (status = 200, description = "Orchestrator status after one manual tick", body = TaskBoardOrchestratorStatus),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn post_task_board_orchestrator_run_once(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardOrchestratorRunOnceRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result = Box::pin(super::task_board_orchestrator_run_once::run(
        &state, &request,
    ))
    .await;
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/runs",
    tag = "task-board",
    description = "List past task-board orchestrator automation runs, paginated and filterable via query parameters",
    params(TaskBoardAutomationHistoryRequest),
    responses(
        (status = 200, description = "Paged automation run history", body = TaskBoardAutomationHistoryResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn get_task_board_automation_runs(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(request): Query<TaskBoardAutomationHistoryRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNS,
        &request_id,
        start,
        task_board_route_executor::automation_runs(&state, &request).await,
    )
}

#[utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/runs/{run_id}",
    tag = "task-board",
    description = "Read a single automation run's full detail, including its per-stage history. Returns an error if the run identifier does not exist",
    params(("run_id" = String, Path, description = "Automation run identifier")),
    responses(
        (status = 200, description = "Automation run detail with stage history", body = TaskBoardAutomationRunDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn get_task_board_automation_run_detail(
    Path(run_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
        &request_id,
        start,
        task_board_route_executor::automation_run_detail(&state, &run_id).await,
    )
}

#[utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/metrics",
    tag = "task-board",
    description = "Read aggregate task-board automation-run metrics: counts by outcome (running, completed, noop, partial, failed, cancelled), open conflicts, and when the snapshot was captured",
    responses(
        (status = 200, description = "Aggregate automation-run metrics", body = TaskBoardAutomationMetrics),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn get_task_board_automation_metrics(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_METRICS,
        &request_id,
        start,
        task_board_route_executor::automation_metrics(&state).await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/task-board/orchestrator/force-cancel",
    tag = "task-board",
    description = "Force-cancel an in-progress task-board automation run. Requires the automation v2 feature flag to be enabled, returning an error otherwise, and every attempt (success or rejection) is recorded as an audit event",
    request_body = TaskBoardAutomationForceCancelRequest,
    responses(
        (status = 200, description = "Disposition of the force-cancel request", body = TaskBoardAutomationForceCancelResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn post_task_board_automation_force_cancel(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardAutomationForceCancelRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_FORCE_CANCEL,
        &request_id,
        start,
        task_board_route_executor::force_cancel_automation(&state, &request).await,
    )
}

#[utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/settings",
    tag = "task-board",
    description = "Read the task-board orchestrator's current settings: enabled workflows, scheduling, retry policy, reviewer config, repository and execution-host configuration, and admission policy",
    responses(
        (status = 200, description = "Current orchestrator settings", body = TaskBoardOrchestratorSettings),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn get_task_board_orchestrator_settings(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        &request_id,
        start,
        task_board_route_executor::orchestrator_settings(&state).await,
    )
}

#[utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/settings",
    tag = "task-board",
    description = "Apply a partial update to the task-board orchestrator settings; only the fields present in the request body are changed. The admission policy, if included, is validated before the update is persisted and a validation failure rejects the whole request",
    request_body = TaskBoardOrchestratorSettingsUpdateRequest,
    responses(
        (status = 200, description = "Orchestrator settings after the update", body = TaskBoardOrchestratorSettings),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn put_task_board_orchestrator_settings(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardOrchestratorSettingsUpdateRequest>,
) -> Response {
    let (start, request_id) = match authenticated_request(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        &request_id,
        start,
        task_board_route_executor::update_orchestrator_settings(&state, &request).await,
    )
}
