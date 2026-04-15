use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;
use axum::{Json, Router};

use crate::daemon::protocol::{
    SessionDetail, TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest,
    TaskQueuePolicyRequest, TaskUpdateRequest,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::DaemonHttpState;
use super::auth::authorize_control_request;
use super::response::{extract_request_id, timed_json};

pub(super) fn task_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route("/v1/sessions/{session_id}/task", post(post_task_create))
        .route(
            "/v1/sessions/{session_id}/tasks/{task_id}/assign",
            post(post_task_assign),
        )
        .route(
            "/v1/sessions/{session_id}/tasks/{task_id}/drop",
            post(post_task_drop),
        )
        .route(
            "/v1/sessions/{session_id}/tasks/{task_id}/queue-policy",
            post(post_task_queue_policy),
        )
        .route(
            "/v1/sessions/{session_id}/tasks/{task_id}/status",
            post(post_task_update),
        )
        .route(
            "/v1/sessions/{session_id}/tasks/{task_id}/checkpoint",
            post(post_task_checkpoint),
        )
}

pub(super) async fn post_task_create(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskCreateRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = task_create_response(&state, &session_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json("POST", "/v1/sessions/{id}/task", &request_id, start, result)
}

pub(super) async fn post_task_assign(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskAssignRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = task_assign_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/assign",
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_drop(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskDropRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = task_drop_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/drop",
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_queue_policy(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskQueuePolicyRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = task_queue_policy_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/queue-policy",
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_update(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskUpdateRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = task_update_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/status",
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_checkpoint(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskCheckpointRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = task_checkpoint_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/checkpoint",
        &request_id,
        start,
        result,
    )
}

async fn task_create_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &TaskCreateRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::create_task_async(session_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::create_task(session_id, request, db_guard.as_deref())
}

async fn task_assign_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskAssignRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::assign_task_async(session_id, task_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::assign_task(session_id, task_id, request, db_guard.as_deref())
}

async fn task_drop_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskDropRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::drop_task_async(session_id, task_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::drop_task(session_id, task_id, request, db_guard.as_deref())
}

async fn task_queue_policy_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskQueuePolicyRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::update_task_queue_policy_async(
            session_id,
            task_id,
            request,
            async_db.as_ref(),
        )
        .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::update_task_queue_policy(session_id, task_id, request, db_guard.as_deref())
}

async fn task_update_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskUpdateRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::update_task_async(session_id, task_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::update_task(session_id, task_id, request, db_guard.as_deref())
}

async fn task_checkpoint_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskCheckpointRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::checkpoint_task_async(session_id, task_id, request, async_db.as_ref())
            .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::checkpoint_task(session_id, task_id, request, db_guard.as_deref())
}

async fn broadcast_task_snapshot(state: &DaemonHttpState, session_id: &str) {
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_session_snapshot_async(
            &state.sender,
            session_id,
            Some(async_db.as_ref()),
        )
        .await;
        return;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::broadcast_session_snapshot(&state.sender, session_id, db_guard.as_deref());
}
