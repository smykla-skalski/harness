use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::{get, post};
use axum::Router;

use crate::daemon::protocol::{
    SessionDetail, TimelineCursor, TimelineWindowRequest, TimelineWindowResponse, http_paths,
};
use crate::daemon::service;
use crate::daemon::timeline::TimelinePayloadScope;
use crate::errors::CliError;

use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};
use super::runtime_session::post_runtime_session;
use super::{DaemonHttpState, require_async_db};

pub(super) use super::sessions_mutations::{
    broadcast_observe_session,
    delete_session,
    post_end_session,
    post_leave_session,
    post_observe_session,
    post_session_archive,
    post_session_join,
    post_session_start,
    post_session_title,
};

pub(super) fn session_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::SESSIONS,
            get(get_sessions).post(post_session_start),
        )
        .route(
            http_paths::SESSIONS_ADOPT,
            post(super::sessions_adopt::post_session_adopt),
        )
        .route(
            http_paths::SESSION_DETAIL,
            get(get_session).delete(delete_session),
        )
        .route(http_paths::SESSION_TIMELINE, get(get_timeline))
        .route(http_paths::SESSION_STREAM, get(super::stream::stream_session))
        .route(http_paths::SESSION_JOIN, post(post_session_join))
        .route(
            http_paths::SESSION_RUNTIME_SESSION,
            post(post_runtime_session),
        )
        .route(http_paths::SESSION_TITLE, post(post_session_title))
        .route(http_paths::SESSION_END, post(post_end_session))
        .route(http_paths::SESSION_ARCHIVE, post(post_session_archive))
        .route(http_paths::SESSION_LEAVE, post(post_leave_session))
        .route(http_paths::SESSION_OBSERVE, post(post_observe_session))
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
    timed_json("GET", http_paths::SESSIONS, &request_id, start, result)
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
            http_paths::SESSION_DETAIL,
            &request_id,
            start,
            result,
        );
    }
    let result = read_session_detail(&state, &session_id, false).await;
    timed_json(
        "GET",
        http_paths::SESSION_DETAIL,
        &request_id,
        start,
        result,
    )
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
    timed_json(
        "GET",
        http_paths::SESSION_TIMELINE,
        &request_id,
        start,
        result,
    )
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
