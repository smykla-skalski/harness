use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;

use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCatalogRequest, TaskBoardCreateItemRequest,
    TaskBoardDeleteItemRequest, TaskBoardDispatchRequest, TaskBoardEvaluateRequest,
    TaskBoardGetItemRequest, TaskBoardListItemsRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardSyncRequest, TaskBoardUpdateItemRequest, http_paths,
};
use crate::daemon::service;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::TaskBoardStatus;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

macro_rules! authenticated_request {
    ($headers:expr, $state:expr) => {{
        let start = Instant::now();
        let request_id = extract_request_id(&$headers);
        if let Err(response) = require_auth(&$headers, &$state) {
            return *response;
        }
        (start, request_id)
    }};
}

pub(super) fn task_board_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::TASK_BOARD_ITEMS,
            post(post_task_board_item).get(get_task_board_items),
        )
        .route(
            http_paths::TASK_BOARD_ITEM,
            get(get_task_board_item)
                .put(put_task_board_item)
                .delete(delete_task_board_item),
        )
        .route(http_paths::TASK_BOARD_SYNC, post(post_task_board_sync))
        .route(
            http_paths::TASK_BOARD_DISPATCH,
            post(post_task_board_dispatch),
        )
        .route(
            http_paths::TASK_BOARD_EVALUATE,
            post(post_task_board_evaluate),
        )
        .route(http_paths::TASK_BOARD_AUDIT, get(get_task_board_audit))
        .route(
            http_paths::TASK_BOARD_PROJECTS,
            get(get_task_board_projects),
        )
        .route(
            http_paths::TASK_BOARD_MACHINES,
            get(get_task_board_machines),
        )
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
            http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
            get(get_task_board_orchestrator_settings).put(put_task_board_orchestrator_settings),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_PIPELINE,
            get(get_task_board_policy_pipeline).put(put_task_board_policy_pipeline_draft),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_SIMULATE,
            post(post_task_board_policy_simulate),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_PROMOTE,
            post(post_task_board_policy_promote),
        )
        .route(
            http_paths::TASK_BOARD_POLICY_AUDIT,
            get(get_task_board_policy_audit),
        )
}

#[derive(Debug, Clone, Default, Deserialize)]
pub(super) struct TaskBoardListQuery {
    pub status: Option<TaskBoardStatus>,
}

pub(in crate::daemon::http) async fn post_task_board_item(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardCreateItemRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ITEMS,
        &request_id,
        start,
        service::create_task_board_item(&request),
    )
}

pub(in crate::daemon::http) async fn get_task_board_items(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let request = TaskBoardListItemsRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEMS,
        &request_id,
        start,
        service::list_task_board_items(&request),
    )
}

pub(in crate::daemon::http) async fn get_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        service::get_task_board_item(&TaskBoardGetItemRequest { id: item_id }),
    )
}

pub(in crate::daemon::http) async fn put_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardUpdateItemRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        service::update_task_board_item(&item_id, &request),
    )
}

pub(in crate::daemon::http) async fn delete_task_board_item(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let request = TaskBoardDeleteItemRequest { id: item_id };
    timed_json(
        "DELETE",
        http_paths::TASK_BOARD_ITEM,
        &request_id,
        start,
        service::delete_task_board_item(&request),
    )
}

async fn post_task_board_sync(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardSyncRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_SYNC,
        &request_id,
        start,
        service::sync_task_board_async(&request).await,
    )
}

async fn post_task_board_dispatch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardDispatchRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    request.actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
    let result = if let Some(async_db) = state.async_db.get() {
        let result = service::dispatch_task_board_async(&request, async_db.as_ref()).await;
        if result
            .as_ref()
            .is_ok_and(|response| !response.applied.is_empty())
        {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        result
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        let result = service::dispatch_task_board(&request, db_ref);
        if result
            .as_ref()
            .is_ok_and(|response| !response.applied.is_empty())
        {
            service::broadcast_sessions_updated(&state.sender, db_ref);
        }
        result
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_DISPATCH,
        &request_id,
        start,
        result,
    )
}

async fn post_task_board_evaluate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardEvaluateRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let result = if let Some(async_db) = state.async_db.get() {
        let result = service::evaluate_task_board_async(&request, async_db.as_ref()).await;
        if result.as_ref().is_ok_and(|response| response.updated > 0) {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        result
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        let result = service::evaluate_task_board(&request, db_ref);
        if result.as_ref().is_ok_and(|response| response.updated > 0) {
            service::broadcast_sessions_updated(&state.sender, db_ref);
        }
        result
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_EVALUATE,
        &request_id,
        start,
        result,
    )
}

async fn get_task_board_audit(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let request = TaskBoardAuditRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_AUDIT,
        &request_id,
        start,
        service::audit_task_board(&request),
    )
}

async fn get_task_board_projects(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let request = TaskBoardCatalogRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_PROJECTS,
        &request_id,
        start,
        service::list_task_board_projects(&request),
    )
}

async fn get_task_board_machines(
    Query(query): Query<TaskBoardListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    let request = TaskBoardCatalogRequest {
        status: query.status,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_MACHINES,
        &request_id,
        start,
        service::list_task_board_machines(&request),
    )
}

async fn get_task_board_orchestrator_status(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
        &request_id,
        start,
        service::task_board_orchestrator_status(),
    )
}

async fn post_task_board_orchestrator_start(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_START,
        &request_id,
        start,
        service::start_task_board_orchestrator(),
    )
}

async fn post_task_board_orchestrator_stop(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
        &request_id,
        start,
        service::stop_task_board_orchestrator(),
    )
}

async fn post_task_board_orchestrator_run_once(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardOrchestratorRunOnceRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    request.actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
    let result = if let Some(async_db) = state.async_db.get() {
        let result =
            service::run_task_board_orchestrator_once_async(&request, async_db.as_ref()).await;
        if result
            .as_ref()
            .is_ok_and(|status| status.last_run_applied_count() > 0)
        {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        result
    } else {
        let db = state.db.get().cloned();
        let request_for_worker = request.clone();
        let result = tokio::task::spawn_blocking(move || {
            let db_guard = db.as_ref().map(|db| db.lock().expect("db lock"));
            let db_ref = db_guard.as_deref();
            service::run_task_board_orchestrator_once(&request_for_worker, db_ref)
        })
        .await
        .unwrap_or_else(|error| {
            Err(crate::errors::CliErrorKind::workflow_io(format!(
                "run task-board orchestrator fallback: {error}"
            ))
            .into())
        });
        if result
            .as_ref()
            .is_ok_and(|status| status.last_run_applied_count() > 0)
        {
            let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
            let db_ref = db_guard.as_deref();
            service::broadcast_sessions_updated(&state.sender, db_ref);
        }
        result
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        &request_id,
        start,
        result,
    )
}

async fn get_task_board_orchestrator_settings(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        &request_id,
        start,
        service::task_board_orchestrator_settings(),
    )
}

async fn put_task_board_orchestrator_settings(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardOrchestratorSettingsUpdateRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        &request_id,
        start,
        service::update_task_board_orchestrator_settings(&request),
    )
}

async fn get_task_board_policy_pipeline(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        &request_id,
        start,
        service::task_board_policy_pipeline(),
    )
}

async fn put_task_board_policy_pipeline_draft(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelineSaveDraftRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        &request_id,
        start,
        service::save_task_board_policy_pipeline_draft(&request),
    )
}

async fn post_task_board_policy_simulate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelineSimulateRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_SIMULATE,
        &request_id,
        start,
        service::simulate_task_board_policy_pipeline(&request),
    )
}

async fn post_task_board_policy_promote(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPolicyPipelinePromoteRequest>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "POST",
        http_paths::TASK_BOARD_POLICY_PROMOTE,
        &request_id,
        start,
        service::promote_task_board_policy_pipeline(&request),
    )
}

async fn get_task_board_policy_audit(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id) = authenticated_request!(headers, state);
    timed_json(
        "GET",
        http_paths::TASK_BOARD_POLICY_AUDIT,
        &request_id,
        start,
        service::audit_task_board_policy_pipeline(),
    )
}
