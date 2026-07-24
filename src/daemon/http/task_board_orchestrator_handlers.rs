use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::daemon::protocol::{
    TaskBoardAutomationForceCancelRequest, TaskBoardAutomationForceCancelResponse,
    TaskBoardAutomationHistoryRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorSettingsUpdateRequest, http_paths,
};
use crate::task_board::{
    TaskBoardAutomationHistoryResponse, TaskBoardAutomationMetrics, TaskBoardAutomationRunDetail,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorStatus,
};

use super::DaemonHttpState;
#[cfg(feature = "openapi")]
use super::openapi::DaemonErrorBody;
use super::response::timed_json;
use super::task_board::{authenticated_request, authorized_control_request_parts};
use super::task_board_route_executor;

/// Wire the orchestrator lifecycle, automation-history, and settings endpoints
/// onto the task-board router. The git-runtime, provider-token, and
/// secret-handoff endpoints live in `task_board_git` so both files stay within
/// the file-length cap.
pub(super) fn merge_orchestrator_routes(
    router: Router<DaemonHttpState>,
) -> Router<DaemonHttpState> {
    router
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
            get(get_task_board_orchestrator_status),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_START,
            post(post_task_board_orchestrator_start),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
            post(post_task_board_orchestrator_stop),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
            post(post_task_board_orchestrator_run_once),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_RUNS,
            get(get_task_board_automation_runs),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
            get(get_task_board_automation_run_detail),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_METRICS,
            get(get_task_board_automation_metrics),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_FORCE_CANCEL,
            post(post_task_board_automation_force_cancel),
        )
        .route(
            http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
            get(get_task_board_orchestrator_settings).put(put_task_board_orchestrator_settings),
        )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/status",
    tag = "task-board",
    responses(
        (status = 200, description = "Current orchestrator status", body = TaskBoardOrchestratorStatus),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/orchestrator/start",
    tag = "task-board",
    responses(
        (status = 200, description = "Orchestrator status after starting the loop", body = TaskBoardOrchestratorStatus),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/orchestrator/stop",
    tag = "task-board",
    responses(
        (status = 200, description = "Orchestrator status after stopping the loop", body = TaskBoardOrchestratorStatus),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/orchestrator/run-once",
    tag = "task-board",
    request_body = TaskBoardOrchestratorRunOnceRequest,
    responses(
        (status = 200, description = "Orchestrator status after one manual tick", body = TaskBoardOrchestratorStatus),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/runs",
    tag = "task-board",
    params(TaskBoardAutomationHistoryRequest),
    responses(
        (status = 200, description = "Paged automation run history", body = TaskBoardAutomationHistoryResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/runs/{run_id}",
    tag = "task-board",
    params(("run_id" = String, Path, description = "Automation run identifier")),
    responses(
        (status = 200, description = "Automation run detail with stage history", body = TaskBoardAutomationRunDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/metrics",
    tag = "task-board",
    responses(
        (status = 200, description = "Aggregate automation-run metrics", body = TaskBoardAutomationMetrics),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/task-board/orchestrator/force-cancel",
    tag = "task-board",
    request_body = TaskBoardAutomationForceCancelRequest,
    responses(
        (status = 200, description = "Disposition of the force-cancel request", body = TaskBoardAutomationForceCancelResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    get,
    path = "/v1/task-board/orchestrator/settings",
    tag = "task-board",
    responses(
        (status = 200, description = "Current orchestrator settings", body = TaskBoardOrchestratorSettings),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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

#[cfg_attr(feature = "openapi", utoipa::path(
    put,
    path = "/v1/task-board/orchestrator/settings",
    tag = "task-board",
    request_body = TaskBoardOrchestratorSettingsUpdateRequest,
    responses(
        (status = 200, description = "Orchestrator settings after the update", body = TaskBoardOrchestratorSettings),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
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
