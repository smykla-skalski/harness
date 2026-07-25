use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::get;
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

use crate::daemon::protocol::{
    SessionDetail, TimelineCursor, TimelineWindowRequest, TimelineWindowResponse, http_paths,
};
use crate::daemon::service;
use crate::daemon::timeline::TimelinePayloadScope;
use harness_kernel::errors::CliError;

use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};
use super::{DaemonHttpState, require_async_db};

use super::openapi::DaemonErrorBody;
use crate::daemon::protocol::SessionSummary;

pub(super) use super::sessions_mutations::broadcast_observe_session;
#[cfg(test)]
pub(super) use super::sessions_mutations::{
    delete_session, post_end_session, post_observe_session, post_session_archive,
    post_session_join, post_session_start, post_session_title,
};

pub(super) fn session_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(
            get_sessions,
            super::sessions_mutations::post_session_start
        ))
        .routes(routes!(super::sessions_adopt::post_session_adopt))
        .routes(routes!(
            get_session,
            super::sessions_mutations::delete_session
        ))
        .routes(routes!(get_timeline))
        .route(
            http_paths::SESSION_STREAM,
            get(super::stream::stream_session),
        )
        .routes(routes!(super::sessions_mutations::post_session_join))
        .routes(routes!(super::runtime_session::post_runtime_session))
        .routes(routes!(super::sessions_mutations::post_session_title))
        .routes(routes!(super::sessions_mutations::post_end_session))
        .routes(routes!(super::sessions_mutations::post_session_archive))
        .routes(routes!(super::sessions_mutations::post_leave_session))
        .routes(routes!(super::sessions_mutations::post_observe_session))
}

#[derive(utoipa::IntoParams)]
#[into_params(parameter_in = Query)]
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

#[utoipa::path(
    get,
    path = "/v1/sessions",
    tag = "sessions",
    description = "List all sessions across projects, including archived and otherwise-excluded sessions",
    responses(
        (status = 200, description = "All sessions across projects", body = Vec<SessionSummary>),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/sessions/{session_id}",
    tag = "sessions",
    description = "Fetch detail for a single session. Pass `scope=core` to receive the reduced core view instead of the full detail",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
        ("scope" = Option<String>, Query, description = "Set to `core` for the reduced core view; any other value or omission returns the full detail"),
    ),
    responses(
        (status = 200, description = "Session detail", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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

#[utoipa::path(
    get,
    path = "/v1/sessions/{session_id}/timeline",
    tag = "sessions",
    description = "Fetch a cursor-paginated window of the session timeline. Pass `scope=summary` to receive summary-only entries instead of full payloads",
    params(
        ("session_id" = String, Path, description = "Session identifier"),
        SessionScopeQuery,
    ),
    responses(
        (status = 200, description = "Timeline window", body = TimelineWindowResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
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
