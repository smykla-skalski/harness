use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::daemon::db::ensure_shared_db;
use crate::daemon::protocol::{
    ControlPlaneActorRequest, ObserveSessionRequest, SessionDetail, SessionEndRequest,
    SessionJoinRequest, SessionLeaveRequest, SessionMutationResponse, SessionStartRequest,
    SessionTitleRequest, TimelineCursor, TimelineWindowRequest, TimelineWindowResponse,
};
use crate::daemon::service;
use crate::daemon::timeline::TimelinePayloadScope;
use crate::errors::CliError;
use crate::session::types::SessionState;

use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};
use super::stream::stream_session;
use super::{DaemonHttpState, require_async_db};

pub(super) fn session_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route("/v1/sessions", get(get_sessions).post(post_session_start))
        .route("/v1/sessions/{session_id}", get(get_session))
        .route("/v1/sessions/{session_id}/timeline", get(get_timeline))
        .route("/v1/sessions/{session_id}/stream", get(stream_session))
        .route("/v1/sessions/{session_id}/join", post(post_session_join))
        .route("/v1/sessions/{session_id}/title", post(post_session_title))
        .route("/v1/sessions/{session_id}/end", post(post_end_session))
        .route("/v1/sessions/{session_id}/leave", post(post_leave_session))
        .route(
            "/v1/sessions/{session_id}/observe",
            post(post_observe_session),
        )
}

#[derive(Debug, Default, serde::Deserialize)]
pub(super) struct SessionScopeQuery {
    #[serde(default)]
    scope: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    known_revision: Option<i64>,
    #[serde(default)]
    before_recorded_at: Option<String>,
    #[serde(default)]
    before_entry_id: Option<String>,
    #[serde(default)]
    after_recorded_at: Option<String>,
    #[serde(default)]
    after_entry_id: Option<String>,
}

impl SessionScopeQuery {
    #[cfg(test)]
    pub(super) fn with_scope(scope: &str) -> Self {
        Self {
            scope: Some(scope.to_string()),
            ..Self::default()
        }
    }

    fn timeline_window_request(&self) -> TimelineWindowRequest {
        TimelineWindowRequest {
            scope: self.scope.clone(),
            limit: self.limit,
            before: timeline_cursor(
                self.before_recorded_at.clone(),
                self.before_entry_id.clone(),
            ),
            after: timeline_cursor(self.after_recorded_at.clone(), self.after_entry_id.clone()),
            known_revision: self.known_revision,
        }
    }
}

fn timeline_cursor(
    recorded_at: Option<String>,
    entry_id: Option<String>,
) -> Option<TimelineCursor> {
    match (recorded_at, entry_id) {
        (Some(recorded_at), Some(entry_id)) => Some(TimelineCursor {
            recorded_at,
            entry_id,
        }),
        _ => None,
    }
}

pub(super) async fn get_sessions(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "sessions") {
        Ok(async_db) => service::list_sessions_async(true, Some(async_db)).await,
        Err(error) => Err(error),
    };
    timed_json("GET", "/v1/sessions", &request_id, start, result)
}

pub(super) async fn get_session(
    Path(session_id): Path<String>,
    query: Query<SessionScopeQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    if query.scope.as_deref() == Some("core") {
        let result = read_session_detail(&state, &session_id, true).await;
        return timed_json(
            "GET",
            "/v1/sessions/{id}?scope=core",
            &request_id,
            start,
            result,
        );
    }
    let result = read_session_detail(&state, &session_id, false).await;
    timed_json("GET", "/v1/sessions/{id}", &request_id, start, result)
}

async fn read_session_detail(
    state: &DaemonHttpState,
    session_id: &str,
    core_only: bool,
) -> Result<SessionDetail, CliError> {
    let async_db = require_async_db(
        state,
        if core_only {
            "session detail core"
        } else {
            "session detail"
        },
    )?;

    if core_only {
        return service::session_detail_core_async(session_id, Some(async_db)).await;
    }

    service::session_detail_async(session_id, Some(async_db)).await
}

pub(super) async fn get_timeline(
    Path(session_id): Path<String>,
    query: Query<SessionScopeQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let timeline_request = query.timeline_window_request();
    let payload_scope = match timeline_request.scope.as_deref() {
        Some("summary") => TimelinePayloadScope::Summary,
        _ => TimelinePayloadScope::Full,
    };
    let read_name = if payload_scope == TimelinePayloadScope::Summary {
        "session timeline summary"
    } else {
        "session timeline"
    };
    let result = read_timeline_window(&state, &session_id, &timeline_request, read_name).await;
    let route = if payload_scope == TimelinePayloadScope::Summary {
        "/v1/sessions/{id}/timeline?scope=summary"
    } else {
        "/v1/sessions/{id}/timeline"
    };
    timed_json("GET", route, &request_id, start, result)
}

async fn read_timeline_window(
    state: &DaemonHttpState,
    session_id: &str,
    timeline_request: &TimelineWindowRequest,
    read_name: &'static str,
) -> Result<TimelineWindowResponse, CliError> {
    let async_db = require_async_db(state, read_name)?;

    service::session_timeline_window_async(session_id, timeline_request, Some(async_db)).await
}

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
    timed_json("POST", "/v1/sessions/{id}/end", &request_id, start, result)
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
        "/v1/sessions/{id}/leave",
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
        "/v1/sessions/{id}/observe",
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

async fn broadcast_observe_session(state: &DaemonHttpState, session_id: &str) {
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
        broadcast_session_start(&state).await;
    }
    timed_json("POST", "/v1/sessions", &request_id, start, result)
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
    timed_json("POST", "/v1/sessions/{id}/join", &request_id, start, result)
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
    timed_json("POST", "/v1/sessions/{id}/title", &request_id, start, result)
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

async fn broadcast_session_start(state: &DaemonHttpState) {
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

async fn broadcast_session_join(state: &DaemonHttpState, session_id: &str) {
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

async fn broadcast_session_title(state: &DaemonHttpState, session_id: &str) {
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

async fn broadcast_session_end(state: &DaemonHttpState, session_id: &str) {
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

fn session_mutation_response(session_state: SessionState) -> SessionMutationResponse {
    SessionMutationResponse {
        state: session_state,
    }
}
