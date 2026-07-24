use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::protocol::{
    SessionDetail, TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskDeleteRequest,
    TaskDropRequest, TaskQueuePolicyRequest, TaskUpdateRequest, http_paths,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::authorize_control_request;
use super::super::response::{extract_request_id, timed_json};
use super::broadcast_task_snapshot;

#[cfg(feature = "openapi")]
use super::super::openapi::DaemonErrorBody;

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/task",
    tag = "tasks",
    params(("session_id" = String, Path, description = "Session identifier")),
    request_body = TaskCreateRequest,
    responses(
        (status = 200, description = "Task created", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(in crate::daemon::http) async fn post_task_create(
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
    timed_json(
        "POST",
        http_paths::SESSION_TASK_CREATE,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/tasks/{task_id}/assign",
    tag = "tasks",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
        ("task_id" = String, Path, description = "Task identifier"),
    ),
    request_body = TaskAssignRequest,
    responses(
        (status = 200, description = "Task assigned", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(in crate::daemon::http) async fn post_task_assign(
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
        http_paths::SESSION_TASK_ASSIGN,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/tasks/{task_id}",
    tag = "tasks",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
        ("task_id" = String, Path, description = "Task identifier"),
    ),
    request_body = TaskDeleteRequest,
    responses(
        (status = 200, description = "Task deleted", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(in crate::daemon::http) async fn post_task_delete(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskDeleteRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = task_delete_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_TASK_DELETE,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/tasks/{task_id}/drop",
    tag = "tasks",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
        ("task_id" = String, Path, description = "Task identifier"),
    ),
    request_body = TaskDropRequest,
    responses(
        (status = 200, description = "Task dropped from the target's queue", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(in crate::daemon::http) async fn post_task_drop(
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
        http_paths::SESSION_TASK_DROP,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/tasks/{task_id}/queue-policy",
    tag = "tasks",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
        ("task_id" = String, Path, description = "Task identifier"),
    ),
    request_body = TaskQueuePolicyRequest,
    responses(
        (status = 200, description = "Task queue policy updated", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(in crate::daemon::http) async fn post_task_queue_policy(
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
        http_paths::SESSION_TASK_QUEUE_POLICY,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/tasks/{task_id}/status",
    tag = "tasks",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
        ("task_id" = String, Path, description = "Task identifier"),
    ),
    request_body = TaskUpdateRequest,
    responses(
        (status = 200, description = "Task status updated", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(in crate::daemon::http) async fn post_task_update(
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
        http_paths::SESSION_TASK_UPDATE,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/tasks/{task_id}/checkpoint",
    tag = "tasks",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
        ("task_id" = String, Path, description = "Task identifier"),
    ),
    request_body = TaskCheckpointRequest,
    responses(
        (status = 200, description = "Task checkpoint recorded", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(in crate::daemon::http) async fn post_task_checkpoint(
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
        http_paths::SESSION_TASK_CHECKPOINT,
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
        return service::assign_task_async(
            session_id,
            task_id,
            request,
            async_db.as_ref(),
            state.wake_dispatch(),
        )
        .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::assign_task(
        session_id,
        task_id,
        request,
        db_guard.as_deref(),
        state.wake_dispatch(),
    )
}

async fn task_delete_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskDeleteRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::delete_task_async(
            session_id,
            task_id,
            request,
            async_db.as_ref(),
            state.wake_dispatch(),
        )
        .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::delete_task(
        session_id,
        task_id,
        request,
        db_guard.as_deref(),
        state.wake_dispatch(),
    )
}

async fn task_drop_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskDropRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::drop_task_async(
            session_id,
            task_id,
            request,
            async_db.as_ref(),
            state.wake_dispatch(),
        )
        .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::drop_task(
        session_id,
        task_id,
        request,
        db_guard.as_deref(),
        state.wake_dispatch(),
    )
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
            state.wake_dispatch(),
        )
        .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::update_task_queue_policy(
        session_id,
        task_id,
        request,
        db_guard.as_deref(),
        state.wake_dispatch(),
    )
}

async fn task_update_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskUpdateRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::update_task_async(
            session_id,
            task_id,
            request,
            async_db.as_ref(),
            state.wake_dispatch(),
        )
        .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::update_task(
        session_id,
        task_id,
        request,
        db_guard.as_deref(),
        state.wake_dispatch(),
    )
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
