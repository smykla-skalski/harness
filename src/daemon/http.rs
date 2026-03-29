use std::convert::Infallible;
use std::sync::{Arc, Mutex};

use async_stream::stream;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use tokio::net::TcpListener;
use tokio::sync::broadcast;

use crate::errors::{CliError, CliErrorKind};

use super::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, ObserveSessionRequest, RoleChangeRequest,
    SessionEndRequest, SignalSendRequest, StreamEvent, TaskAssignRequest, TaskCheckpointRequest,
    TaskCreateRequest, TaskUpdateRequest,
};
use super::service;
use super::state::DaemonManifest;
use super::websocket::ReplayBuffer;

#[derive(Debug, Clone)]
pub struct DaemonHttpState {
    pub token: String,
    pub sender: broadcast::Sender<StreamEvent>,
    pub manifest: DaemonManifest,
    pub daemon_epoch: String,
    pub replay_buffer: Arc<Mutex<ReplayBuffer>>,
}

/// Serve the daemon's HTTP API.
///
/// # Errors
/// Returns `CliError` on listener failures.
pub async fn serve(listener: TcpListener, state: DaemonHttpState) -> Result<(), CliError> {
    let app = Router::new()
        .route("/v1/health", get(get_health))
        .route("/v1/diagnostics", get(get_diagnostics))
        .route("/v1/projects", get(get_projects))
        .route("/v1/sessions", get(get_sessions))
        .route("/v1/sessions/{session_id}", get(get_session))
        .route("/v1/sessions/{session_id}/timeline", get(get_timeline))
        .route("/v1/ws", get(super::websocket::ws_upgrade_handler))
        .route("/v1/stream", get(stream_global))
        .route("/v1/sessions/{session_id}/stream", get(stream_session))
        .route("/v1/sessions/{session_id}/task", post(post_task_create))
        .route(
            "/v1/sessions/{session_id}/tasks/{task_id}/assign",
            post(post_task_assign),
        )
        .route(
            "/v1/sessions/{session_id}/tasks/{task_id}/status",
            post(post_task_update),
        )
        .route(
            "/v1/sessions/{session_id}/tasks/{task_id}/checkpoint",
            post(post_task_checkpoint),
        )
        .route(
            "/v1/sessions/{session_id}/agents/{agent_id}/role",
            post(post_role_change),
        )
        .route(
            "/v1/sessions/{session_id}/agents/{agent_id}/remove",
            post(post_remove_agent),
        )
        .route(
            "/v1/sessions/{session_id}/leader",
            post(post_transfer_leader),
        )
        .route("/v1/sessions/{session_id}/end", post(post_end_session))
        .route("/v1/sessions/{session_id}/signal", post(post_send_signal))
        .route(
            "/v1/sessions/{session_id}/observe",
            post(post_observe_session),
        )
        .with_state(state);

    axum::serve(listener, app).await.map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "serve daemon http api: {error}"
        )))
    })
}

async fn get_health(State(state): State<DaemonHttpState>) -> Response {
    map_json(service::health_response(&state.manifest))
}

async fn get_diagnostics(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    map_json(service::diagnostics_report())
}

async fn get_projects(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    map_json(service::list_projects())
}

async fn get_sessions(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    map_json(service::list_sessions(true))
}

async fn get_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    map_json(service::session_detail(&session_id))
}

async fn get_timeline(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    map_json(service::session_timeline(&session_id))
}

async fn post_task_create(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskCreateRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::create_task(&session_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_task_assign(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskAssignRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::assign_task(&session_id, &task_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_task_update(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskUpdateRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::update_task(&session_id, &task_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_task_checkpoint(
    Path((session_id, task_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskCheckpointRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::checkpoint_task(&session_id, &task_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_role_change(
    Path((session_id, agent_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<RoleChangeRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::change_role(&session_id, &agent_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_remove_agent(
    Path((session_id, agent_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentRemoveRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::remove_agent(&session_id, &agent_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_transfer_leader(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<LeaderTransferRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::transfer_leader(&session_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_end_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SessionEndRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::end_session(&session_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_send_signal(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SignalSendRequest>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let response = map_json(service::send_signal(&session_id, &request));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn post_observe_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    request: Option<Json<ObserveSessionRequest>>,
) -> Response {
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let request = request.map(|Json(request)| request);
    let response = map_json(service::observe_session(&session_id, request.as_ref()));
    let _ = state
        .sender
        .send(service::refresh_event("session_updated", Some(&session_id)));
    response
}

async fn stream_global(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Result<Sse<impl futures_util::Stream<Item = Result<Event, Infallible>>>, Response> {
    require_auth(&headers, &state).map_err(|response| *response)?;
    let mut receiver = state.sender.subscribe();
    let stream = stream! {
        yield Ok(Event::default().event("ready").json_data(service::refresh_event("ready", None)).expect("serialize ready event"));
        loop {
            match receiver.recv().await {
                Ok(event) => {
                    let event_name = event.event.clone();
                    yield Ok(Event::default().event(&event_name).json_data(event).expect("serialize stream event"));
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    };
    Ok(Sse::new(stream).keep_alive(KeepAlive::default()))
}

async fn stream_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Result<Sse<impl futures_util::Stream<Item = Result<Event, Infallible>>>, Response> {
    require_auth(&headers, &state).map_err(|response| *response)?;
    let mut receiver = state.sender.subscribe();
    let stream = stream! {
        yield Ok(Event::default().event("ready").json_data(service::refresh_event("ready", Some(&session_id))).expect("serialize ready event"));
        loop {
            match receiver.recv().await {
                Ok(event) => {
                    if event.session_id.as_deref().is_some_and(|current| current != session_id) {
                        continue;
                    }
                    let event_name = event.event.clone();
                    yield Ok(Event::default().event(&event_name).json_data(event).expect("serialize stream event"));
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    };
    Ok(Sse::new(stream).keep_alive(KeepAlive::default()))
}

fn map_json<T: serde::Serialize>(result: Result<T, CliError>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(error) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "error": {
                    "code": error.code(),
                    "message": error.message(),
                    "details": error.details(),
                }
            })),
        )
            .into_response(),
    }
}

pub(super) fn require_auth(headers: &HeaderMap, state: &DaemonHttpState) -> Result<(), Box<Response>> {
    let provided = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim);
    if provided == Some(state.token.as_str()) {
        return Ok(());
    }
    Err(Box::new(
        (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({
                "error": {
                    "code": "DAEMON_AUTH",
                    "message": "missing or invalid daemon bearer token",
                }
            })),
        )
            .into_response(),
    ))
}
