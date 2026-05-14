use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;

use crate::daemon::protocol::{
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardListItemsRequest, TaskBoardUpdateItemRequest, http_paths,
};
use crate::daemon::service;
use crate::task_board::TaskBoardStatus;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

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
        .route(http_paths::TASK_BOARD_AUDIT, get(get_task_board_audit))
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
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
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
) -> Response {
    task_board_capability_response(
        "POST",
        http_paths::TASK_BOARD_SYNC,
        "sync",
        &headers,
        &state,
    )
}

async fn post_task_board_dispatch(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    task_board_capability_response(
        "POST",
        http_paths::TASK_BOARD_DISPATCH,
        "dispatch",
        &headers,
        &state,
    )
}

async fn get_task_board_audit(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    task_board_capability_response(
        "GET",
        http_paths::TASK_BOARD_AUDIT,
        "audit",
        &headers,
        &state,
    )
}

fn task_board_capability_response(
    method: &'static str,
    path: &'static str,
    operation: &'static str,
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(headers);
    if let Err(response) = require_auth(headers, state) {
        return *response;
    }
    timed_json(
        method,
        path,
        &request_id,
        start,
        Ok(service::task_board_not_configured(operation)),
    )
}
