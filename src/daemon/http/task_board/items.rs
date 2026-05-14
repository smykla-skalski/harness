use std::time::Instant;

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCatalogRequest, TaskBoardCreateItemRequest,
    TaskBoardDeleteItemRequest, TaskBoardDispatchRequest, TaskBoardEvaluateRequest,
    TaskBoardGetItemRequest, TaskBoardListItemsRequest, TaskBoardSyncRequest,
    TaskBoardUpdateItemRequest, http_paths,
};
use crate::daemon::service;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::TaskBoardStatus;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};

#[derive(Debug, Clone, Default, Deserialize)]
pub(super) struct TaskBoardListQuery {
    pub status: Option<TaskBoardStatus>,
}

macro_rules! authenticated_parts {
    ($headers:expr, $state:expr) => {{
        match authenticated_request(&$headers, &$state) {
            Ok(parts) => parts,
            Err(response) => return *response,
        }
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
        service::create_task_board_item(&request),
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
        service::list_task_board_items(&request),
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
        service::get_task_board_item(&TaskBoardGetItemRequest { id: item_id }),
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
        service::update_task_board_item(&item_id, &request),
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
        service::delete_task_board_item(&request),
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
        service::sync_task_board_async(&request).await,
    )
}

pub(super) async fn post_task_board_dispatch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardDispatchRequest>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
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

pub(super) async fn post_task_board_evaluate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardEvaluateRequest>,
) -> Response {
    let (start, request_id) = authenticated_parts!(headers, state);
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
        service::audit_task_board(&request),
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
        service::list_task_board_projects(&request),
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
        service::list_task_board_machines(&request),
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
