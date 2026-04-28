use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::protocol::{
    SessionDetail, TaskArbitrateRequest, TaskClaimReviewRequest, TaskRespondReviewRequest,
    TaskSubmitForReviewRequest, TaskSubmitReviewRequest, http_paths,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::authorize_control_request;
use super::super::response::{extract_request_id, timed_json};
use super::broadcast_task_snapshot;

pub(in crate::daemon::http) async fn post_task_submit_for_review(
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

pub(in crate::daemon::http) async fn post_task_claim_review(
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

pub(in crate::daemon::http) async fn post_task_submit_review(
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

pub(in crate::daemon::http) async fn post_task_respond_review(
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

pub(in crate::daemon::http) async fn post_task_arbitrate(
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
        return service::submit_review_async(session_id, task_id, request, async_db.as_ref()).await;
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
