use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;

use crate::daemon::db::ensure_shared_db;
use crate::daemon::protocol::{
    ControlPlaneActorRequest, ObserveSessionRequest, SessionArchiveRequest, SessionArchiveResponse,
    SessionDetail, SessionEndRequest, SessionJoinRequest, SessionLeaveRequest,
    SessionMutationResponse, SessionStartRequest, SessionTitleRequest, http_paths,
};
use crate::daemon::service;
use crate::errors::CliError;
use crate::session::types::SessionState;

use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};
use super::DaemonHttpState;

pub(super) async fn post_end_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<SessionEndRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = end_session_response(&state, &session_id, &request).await;
    if result.is_ok() {
        broadcast_session_end(&state, &session_id).await;
    }
    timed_json("POST", http_paths::SESSION_END, &request_id, start, result)
}

pub(super) async fn post_session_archive(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<SessionArchiveRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = archive_session_response(&state, &session_id, &request).await;
    if result.is_ok() {
        broadcast_sessions_list_changed(&state).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_ARCHIVE,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_leave_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SessionLeaveRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = leave_session_response(&state, &session_id, &request).await;
    if result.is_ok() {
        broadcast_session_end(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_LEAVE,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_observe_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    request: Option<Json<ObserveSessionRequest>>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let mut request = request.map(|Json(request)| request);
    if let Some(request) = request.as_mut() {
        request.bind_control_plane_actor();
    }
    let result = observe_session_response(&state, &session_id, request.as_ref()).await;
    if result.is_ok() {
        broadcast_observe_session(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_OBSERVE,
        &request_id,
        start,
        result,
    )
}

async fn observe_session_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: Option<&ObserveSessionRequest>,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::observe_session_async(session_id, request, async_db.as_ref()).await;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    service::observe_session(session_id, request, db_ref)
}

pub(super) async fn broadcast_observe_session(state: &DaemonHttpState, session_id: &str) {
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
    let db_ref = db_guard.as_deref();
    service::broadcast_session_snapshot(&state.sender, session_id, db_ref);
}

pub(super) async fn post_session_start(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SessionStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = start_session_response(&state, &request).await;
    if result.is_ok() {
        broadcast_sessions_list_changed(&state).await;
    }
    timed_json("POST", http_paths::SESSIONS, &request_id, start, result)
}

pub(super) async fn post_session_join(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SessionJoinRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = join_session_response(&state, &session_id, &request).await;
    if result.is_ok() {
        broadcast_session_join(&state, &session_id).await;
    }
    timed_json("POST", http_paths::SESSION_JOIN, &request_id, start, result)
}

pub(super) async fn post_session_title(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SessionTitleRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = title_session_response(&state, &session_id, &request).await;
    if result.is_ok() {
        broadcast_session_title(&state, &session_id).await;
    }
    timed_json(
        "POST",
        http_paths::SESSION_TITLE,
        &request_id,
        start,
        result,
    )
}

async fn start_session_response(
    state: &DaemonHttpState,
    request: &SessionStartRequest,
) -> Result<SessionMutationResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::start_session_direct_async(request, async_db.as_ref())
            .await
            .map(session_mutation_response);
    }
    let db = ensure_shared_db(&state.db)?;
    let db_guard = db.lock().expect("db lock");
    service::start_session_direct(request, Some(&db_guard)).map(session_mutation_response)
}

async fn broadcast_sessions_list_changed(state: &DaemonHttpState) {
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        return;
    }
    if let Ok(db) = ensure_shared_db(&state.db) {
        let db_guard = db.lock().expect("db lock");
        service::broadcast_sessions_updated(&state.sender, Some(&db_guard));
    }
}

async fn join_session_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &SessionJoinRequest,
) -> Result<SessionMutationResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::join_session_direct_async(session_id, request, async_db.as_ref())
            .await
            .map(session_mutation_response);
    }
    let db = ensure_shared_db(&state.db)?;
    let db_guard = db.lock().expect("db lock");
    service::join_session_direct(session_id, request, Some(&db_guard))
        .map(session_mutation_response)
}

async fn title_session_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &SessionTitleRequest,
) -> Result<SessionMutationResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::update_session_title_direct_async(session_id, request, async_db.as_ref())
            .await
            .map(session_mutation_response);
    }
    let db = ensure_shared_db(&state.db)?;
    let db_guard = db.lock().expect("db lock");
    service::update_session_title_direct(session_id, request, &db_guard)
        .map(session_mutation_response)
}

async fn end_session_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &SessionEndRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::end_session_async(session_id, request, async_db.as_ref()).await;
    }
    let db = ensure_shared_db(&state.db)?;
    let db_guard = db.lock().expect("db lock");
    service::end_session(session_id, request, Some(&db_guard))
}

async fn archive_session_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &SessionArchiveRequest,
) -> Result<SessionArchiveResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::archive_session_async(session_id, request, async_db.as_ref()).await;
    }
    let db = ensure_shared_db(&state.db)?;
    let db_guard = db.lock().expect("db lock");
    service::archive_session(session_id, request, Some(&db_guard))
}

async fn leave_session_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &SessionLeaveRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return service::leave_session_async(session_id, request, async_db.as_ref()).await;
    }
    let db = ensure_shared_db(&state.db)?;
    let db_guard = db.lock().expect("db lock");
    service::leave_session(session_id, request, Some(&db_guard))
}

async fn broadcast_session_snapshot_for(state: &DaemonHttpState, session_id: &str) {
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_session_snapshot_async(
            &state.sender,
            session_id,
            Some(async_db.as_ref()),
        )
        .await;
        return;
    }
    if let Ok(db) = ensure_shared_db(&state.db) {
        let db_guard = db.lock().expect("db lock");
        service::broadcast_session_snapshot(&state.sender, session_id, Some(&db_guard));
    }
}

async fn broadcast_session_join(state: &DaemonHttpState, session_id: &str) {
    broadcast_session_snapshot_for(state, session_id).await;
}

async fn broadcast_session_title(state: &DaemonHttpState, session_id: &str) {
    broadcast_session_snapshot_for(state, session_id).await;
}

async fn broadcast_session_end(state: &DaemonHttpState, session_id: &str) {
    broadcast_session_snapshot_for(state, session_id).await;
}

fn session_mutation_response(session_state: SessionState) -> SessionMutationResponse {
    SessionMutationResponse {
        state: session_state,
    }
}

pub(super) async fn delete_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    use axum::response::IntoResponse as _;
    if let Err(r) = require_auth(&headers, &state) {
        return *r;
    }
    let found = if let Some(async_db) = state.async_db.get() {
        service::delete_session_direct_async(&session_id, async_db.as_ref()).await
    } else {
        ensure_shared_db(&state.db).and_then(|db| {
            service::delete_session_direct(&session_id, Some(&db.lock().expect("db lock")))
        })
    };
    match found {
        Ok(true) => {
            broadcast_sessions_list_changed(&state).await;
            StatusCode::NO_CONTENT.into_response()
        }
        Ok(false) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "session not found"})),
        )
            .into_response(),
        Err(error) => super::response::map_json(Err::<SessionState, _>(error)),
    }
}
