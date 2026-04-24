use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;
use axum::{Json, Router};

use crate::daemon::protocol::{
    SessionDetail, TaskArbitrateRequest, TaskAssignRequest, TaskCheckpointRequest,
    TaskClaimReviewRequest, TaskCreateRequest, TaskDropRequest, TaskQueuePolicyRequest,
    TaskRespondReviewRequest, TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
    TaskUpdateRequest, http_paths,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::DaemonHttpState;
use super::auth::authorize_control_request;
use super::response::{extract_request_id, timed_json};

pub(super) fn task_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(http_paths::SESSION_TASK_CREATE, post(post_task_create))
        .route(http_paths::SESSION_TASK_ASSIGN, post(post_task_assign))
        .route(http_paths::SESSION_TASK_DROP, post(post_task_drop))
        .route(
            http_paths::SESSION_TASK_QUEUE_POLICY,
            post(post_task_queue_policy),
        )
        .route(http_paths::SESSION_TASK_UPDATE, post(post_task_update))
        .route(
            http_paths::SESSION_TASK_CHECKPOINT,
            post(post_task_checkpoint),
        )
        .route(
            http_paths::SESSION_TASK_SUBMIT_FOR_REVIEW,
            post(post_task_submit_for_review),
        )
        .route(
            http_paths::SESSION_TASK_CLAIM_REVIEW,
            post(post_task_claim_review),
        )
        .route(
            http_paths::SESSION_TASK_SUBMIT_REVIEW,
            post(post_task_submit_review),
        )
        .route(
            http_paths::SESSION_TASK_RESPOND_REVIEW,
            post(post_task_respond_review),
        )
        .route(
            http_paths::SESSION_TASK_ARBITRATE,
            post(post_task_arbitrate),
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
    timed_json(
        "POST",
        http_paths::SESSION_TASK_CREATE,
        &request_id,
        start,
        result,
    )
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
        http_paths::SESSION_TASK_ASSIGN,
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
        http_paths::SESSION_TASK_DROP,
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
        http_paths::SESSION_TASK_QUEUE_POLICY,
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
        http_paths::SESSION_TASK_UPDATE,
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

pub(super) async fn post_task_submit_for_review(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskSubmitForReviewRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = submit_for_review_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_TASK_SUBMIT_FOR_REVIEW,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_claim_review(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskClaimReviewRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = claim_review_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_TASK_CLAIM_REVIEW,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_submit_review(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskSubmitReviewRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = submit_review_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_TASK_SUBMIT_REVIEW,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_respond_review(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskRespondReviewRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = respond_review_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_TASK_RESPOND_REVIEW,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_task_arbitrate(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskArbitrateRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = arbitrate_response(&state, &session_id, &task_id, &request).await;
    if result.is_ok() {
        broadcast_task_snapshot(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_TASK_ARBITRATE,
        &request_id,
        start,
        result,
    )
}

async fn submit_for_review_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskSubmitForReviewRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::submit_for_review_async(session_id, task_id, request, async_db.as_ref())
            .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::submit_for_review(session_id, task_id, request, db_guard.as_deref())
}

async fn claim_review_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskClaimReviewRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::claim_review_async(session_id, task_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::claim_review(session_id, task_id, request, db_guard.as_deref())
}

async fn submit_review_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskSubmitReviewRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::submit_review_async(session_id, task_id, request, async_db.as_ref())
            .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::submit_review(session_id, task_id, request, db_guard.as_deref())
}

async fn respond_review_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskRespondReviewRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::respond_review_async(session_id, task_id, request, async_db.as_ref())
            .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::respond_review(session_id, task_id, request, db_guard.as_deref())
}

async fn arbitrate_response(
    state: &DaemonHttpState,
    session_id: &str,
    task_id: &str,
    request: &TaskArbitrateRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::arbitrate_review_async(session_id, task_id, request, async_db.as_ref())
            .await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::arbitrate_review(session_id, task_id, request, db_guard.as_deref())
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
