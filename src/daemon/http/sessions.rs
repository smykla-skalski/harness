use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::daemon::protocol::{
    ControlPlaneActorRequest, ObserveSessionRequest, SessionEndRequest, SessionJoinRequest,
    SessionMutationResponse, SessionStartRequest, TimelineCursor, TimelineWindowRequest,
};
use crate::daemon::read_cache::run_preferred_db_read;
use crate::daemon::service;
use crate::daemon::timeline::TimelinePayloadScope;

use super::DaemonHttpState;
use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};
use super::stream::stream_session;

pub(super) fn session_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route("/v1/sessions", get(get_sessions).post(post_session_start))
        .route("/v1/sessions/{session_id}", get(get_session))
        .route("/v1/sessions/{session_id}/timeline", get(get_timeline))
        .route("/v1/sessions/{session_id}/stream", get(stream_session))
        .route("/v1/sessions/{session_id}/join", post(post_session_join))
        .route("/v1/sessions/{session_id}/end", post(post_end_session))
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

async fn get_sessions(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = run_preferred_db_read(
        &state.db,
        "sessions",
        |db| service::list_sessions(true, Some(db)),
        || service::list_sessions(true, None),
    )
    .await;
    timed_json("GET", "/v1/sessions", &request_id, start, result)
}

async fn get_session(
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
        let result = run_preferred_db_read(
            &state.db,
            "session detail core",
            {
                let session_id = session_id.clone();
                move |db| service::session_detail_core(&session_id, Some(db))
            },
            || service::session_detail_core(&session_id, None),
        )
        .await;
        return timed_json(
            "GET",
            "/v1/sessions/{id}?scope=core",
            &request_id,
            start,
            result,
        );
    }
    let result = run_preferred_db_read(
        &state.db,
        "session detail",
        {
            let session_id = session_id.clone();
            move |db| service::session_detail(&session_id, Some(db))
        },
        || service::session_detail(&session_id, None),
    )
    .await;
    timed_json("GET", "/v1/sessions/{id}", &request_id, start, result)
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
    let result = run_preferred_db_read(
        &state.db,
        read_name,
        {
            let session_id = session_id.clone();
            let timeline_request = timeline_request.clone();
            move |db| service::session_timeline_window(&session_id, &timeline_request, Some(db))
        },
        || service::session_timeline_window(&session_id, &timeline_request, None),
    )
    .await;
    let route = if payload_scope == TimelinePayloadScope::Summary {
        "/v1/sessions/{id}/timeline?scope=summary"
    } else {
        "/v1/sessions/{id}/timeline"
    };
    timed_json("GET", route, &request_id, start, result)
}

async fn post_end_session(
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::end_session(&session_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json("POST", "/v1/sessions/{id}/end", &request_id, start, result)
}

async fn post_observe_session(
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let mut request = request.map(|Json(request)| request);
    if let Some(request) = request.as_mut() {
        request.bind_control_plane_actor();
    }
    let result = service::observe_session(&session_id, request.as_ref(), db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/observe",
        &request_id,
        start,
        result,
    )
}

async fn post_session_start(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SessionStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match crate::daemon::db::ensure_shared_db(&state.db) {
        Ok(db) => {
            let db_guard = db.lock().expect("db lock");
            service::start_session_direct(&request, Some(&db_guard)).map(|session_state| {
                SessionMutationResponse {
                    state: session_state,
                }
            })
        }
        Err(error) => Err(error),
    };
    if result.is_ok()
        && let Ok(db) = crate::daemon::db::ensure_shared_db(&state.db)
    {
        let db_guard = db.lock().expect("db lock");
        service::broadcast_sessions_updated(&state.sender, Some(&db_guard));
    }
    timed_json("POST", "/v1/sessions", &request_id, start, result)
}

async fn post_session_join(
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
    let result = match crate::daemon::db::ensure_shared_db(&state.db) {
        Ok(db) => {
            let db_guard = db.lock().expect("db lock");
            service::join_session_direct(&session_id, &request, Some(&db_guard)).map(
                |session_state| SessionMutationResponse {
                    state: session_state,
                },
            )
        }
        Err(error) => Err(error),
    };
    if result.is_ok()
        && let Ok(db) = crate::daemon::db::ensure_shared_db(&state.db)
    {
        let db_guard = db.lock().expect("db lock");
        service::broadcast_session_snapshot(&state.sender, &session_id, Some(&db_guard));
    }
    timed_json("POST", "/v1/sessions/{id}/join", &request_id, start, result)
}
