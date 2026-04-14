use std::convert::Infallible;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Instant;

use async_stream::stream;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use tokio::net::TcpListener;
use tokio::sync::{broadcast, watch};

use crate::errors::{CliError, CliErrorKind};
use crate::session::persona;

use super::agent_tui::{AgentTuiInputRequest, AgentTuiResizeRequest, AgentTuiStartRequest};
use super::protocol::{
    AgentRemoveRequest, CodexApprovalDecisionRequest, CodexRunRequest, CodexSteerRequest,
    ControlPlaneActorRequest, HostBridgeReconfigureRequest, LeaderTransferRequest,
    ObserveSessionRequest, RoleChangeRequest, SessionEndRequest, SessionJoinRequest,
    SessionMutationResponse, SessionStartRequest, SetLogLevelRequest, SignalAckRequest,
    SignalCancelRequest, SignalSendRequest, StreamEvent, TaskAssignRequest, TaskCheckpointRequest,
    TaskCreateRequest, TaskDropRequest, TaskQueuePolicyRequest, TaskUpdateRequest, TimelineCursor,
    TimelineWindowRequest, VoiceAudioChunkRequest, VoiceSessionFinishRequest,
    VoiceSessionStartRequest, VoiceTranscriptUpdateRequest,
};
use super::read_cache::run_preferred_db_read;
use super::service;
use super::state::DaemonManifest;
use super::websocket::ReplayBuffer;

#[derive(Clone)]
pub struct DaemonHttpState {
    pub token: String,
    pub sender: broadcast::Sender<StreamEvent>,
    pub manifest: DaemonManifest,
    pub daemon_epoch: String,
    pub replay_buffer: Arc<Mutex<ReplayBuffer>>,
    pub db: Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
    pub codex_controller: super::codex_controller::CodexControllerHandle,
    pub agent_tui_manager: super::agent_tui::AgentTuiManagerHandle,
}

/// Serve the daemon's HTTP API.
///
/// # Errors
/// Returns `CliError` on listener failures.
pub async fn serve(
    listener: TcpListener,
    state: DaemonHttpState,
    mut shutdown_rx: watch::Receiver<bool>,
) -> Result<(), CliError> {
    let app = daemon_http_router().with_state(state);

    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            if *shutdown_rx.borrow() {
                return;
            }
            while shutdown_rx.changed().await.is_ok() {
                if *shutdown_rx.borrow() {
                    break;
                }
            }
        })
        .await
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "serve daemon http api: {error}"
            )))
        })
}

fn daemon_http_router() -> Router<DaemonHttpState> {
    Router::new()
        .merge(core_routes())
        .merge(session_routes())
        .merge(task_routes())
        .merge(agent_routes())
        .merge(agent_tui_routes())
        .merge(signal_routes())
        .merge(codex_routes())
        .merge(voice_routes())
}

fn try_db_guard(state: &DaemonHttpState) -> Option<MutexGuard<'_, super::db::DaemonDb>> {
    state.db.get().and_then(|db| db.try_lock().ok())
}

fn authorize_control_request<T: ControlPlaneActorRequest>(
    headers: &HeaderMap,
    state: &DaemonHttpState,
    request: &mut T,
) -> Result<(), Box<Response>> {
    require_auth(headers, state)?;
    request.bind_control_plane_actor();
    Ok(())
}

fn core_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route("/v1/health", get(get_health))
        .route("/v1/diagnostics", get(get_diagnostics))
        .route("/v1/daemon/stop", post(post_stop_daemon))
        .route("/v1/bridge/reconfigure", post(post_bridge_reconfigure))
        .route(
            "/v1/daemon/log-level",
            get(get_log_level).put(put_log_level),
        )
        .route("/v1/personas", get(get_personas))
        .route("/v1/projects", get(get_projects))
        .route("/v1/ws", get(super::websocket::ws_upgrade_handler))
        .route("/v1/stream", get(stream_global))
}

fn session_routes() -> Router<DaemonHttpState> {
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
        .route(
            "/v1/sessions/{session_id}/voice-sessions",
            post(post_voice_session),
        )
}

fn task_routes() -> Router<DaemonHttpState> {
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

fn agent_routes() -> Router<DaemonHttpState> {
    Router::new()
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
}

fn agent_tui_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            "/v1/sessions/{session_id}/agent-tuis",
            get(get_agent_tuis).post(post_agent_tui_start),
        )
        .route("/v1/agent-tuis/{tui_id}", get(get_agent_tui))
        .route("/v1/agent-tuis/{tui_id}/input", post(post_agent_tui_input))
        .route(
            "/v1/agent-tuis/{tui_id}/resize",
            post(post_agent_tui_resize),
        )
        .route("/v1/agent-tuis/{tui_id}/stop", post(post_agent_tui_stop))
        .route("/v1/agent-tuis/{tui_id}/ready", post(post_agent_tui_ready))
}

fn signal_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route("/v1/sessions/{session_id}/signal", post(post_send_signal))
        .route(
            "/v1/sessions/{session_id}/signal-cancel",
            post(post_cancel_signal),
        )
        .route(
            "/v1/sessions/{session_id}/signal-ack",
            post(post_signal_ack),
        )
}

fn codex_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            "/v1/sessions/{session_id}/codex-runs",
            get(get_codex_runs).post(post_codex_run),
        )
        .route("/v1/codex-runs/{run_id}", get(get_codex_run))
        .route("/v1/codex-runs/{run_id}/steer", post(post_codex_steer))
        .route(
            "/v1/codex-runs/{run_id}/interrupt",
            post(post_codex_interrupt),
        )
        .route(
            "/v1/codex-runs/{run_id}/approvals/{approval_id}",
            post(post_codex_approval),
        )
}

fn voice_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            "/v1/voice-sessions/{voice_session_id}/audio",
            post(post_voice_audio_chunk),
        )
        .route(
            "/v1/voice-sessions/{voice_session_id}/transcript",
            post(post_voice_transcript),
        )
        .route(
            "/v1/voice-sessions/{voice_session_id}/finish",
            post(post_voice_finish),
        )
}

async fn get_health(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let db_guard = try_db_guard(&state);
    let db_ref = db_guard.as_deref();
    timed_json(
        "GET",
        "/v1/health",
        &request_id,
        start,
        service::health_response(&state.manifest, db_ref),
    )
}

async fn get_diagnostics(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let db_guard = try_db_guard(&state);
    timed_json(
        "GET",
        "/v1/diagnostics",
        &request_id,
        start,
        service::diagnostics_report(db_guard.as_deref()),
    )
}

async fn get_personas(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let personas = persona::all();
    timed_json(
        "GET",
        "/v1/personas",
        &request_id,
        start,
        Ok::<_, CliError>(personas),
    )
}

async fn post_stop_daemon(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/daemon/stop",
        &request_id,
        start,
        service::request_shutdown(),
    )
}

async fn post_bridge_reconfigure(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<HostBridgeReconfigureRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/bridge/reconfigure",
        &request_id,
        start,
        super::bridge::reconfigure_bridge(&request.enable, &request.disable, request.force),
    )
}

async fn get_log_level(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        "/v1/daemon/log-level",
        &request_id,
        start,
        service::get_log_level(),
    )
}

async fn put_log_level(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SetLogLevelRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "PUT",
        "/v1/daemon/log-level",
        &request_id,
        start,
        service::set_log_level(&request, &state.sender),
    )
}

async fn get_projects(headers: HeaderMap, State(state): State<DaemonHttpState>) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = run_preferred_db_read(
        &state.db,
        "projects",
        |db| service::list_projects(Some(db)),
        || service::list_projects(None),
    )
    .await;
    timed_json("GET", "/v1/projects", &request_id, start, result)
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

#[derive(Debug, Default, serde::Deserialize)]
struct SessionScopeQuery {
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

async fn get_timeline(
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
        Some("summary") => super::timeline::TimelinePayloadScope::Summary,
        _ => super::timeline::TimelinePayloadScope::Full,
    };
    let read_name = if payload_scope == super::timeline::TimelinePayloadScope::Summary {
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
    let route = if payload_scope == super::timeline::TimelinePayloadScope::Summary {
        "/v1/sessions/{id}/timeline?scope=summary"
    } else {
        "/v1/sessions/{id}/timeline"
    };
    timed_json("GET", route, &request_id, start, result)
}

async fn post_task_create(
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::create_task(&session_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json("POST", "/v1/sessions/{id}/task", &request_id, start, result)
}

async fn post_task_assign(
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::assign_task(&session_id, &task_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/assign",
        &request_id,
        start,
        result,
    )
}

async fn post_task_drop(
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::drop_task(&session_id, &task_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/drop",
        &request_id,
        start,
        result,
    )
}

async fn post_task_queue_policy(
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::update_task_queue_policy(&session_id, &task_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/queue-policy",
        &request_id,
        start,
        result,
    )
}

async fn post_task_update(
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::update_task(&session_id, &task_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/status",
        &request_id,
        start,
        result,
    )
}

async fn post_task_checkpoint(
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::checkpoint_task(&session_id, &task_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/tasks/{id}/checkpoint",
        &request_id,
        start,
        result,
    )
}

async fn post_role_change(
    Path((session_id, agent_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<RoleChangeRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::change_role(&session_id, &agent_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/agents/{id}/role",
        &request_id,
        start,
        result,
    )
}

async fn post_remove_agent(
    Path((session_id, agent_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<AgentRemoveRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::remove_agent(&session_id, &agent_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/agents/{id}/remove",
        &request_id,
        start,
        result,
    )
}

async fn post_transfer_leader(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<LeaderTransferRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::transfer_leader(&session_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/leader",
        &request_id,
        start,
        result,
    )
}

async fn get_agent_tuis(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        "/v1/sessions/{id}/agent-tuis",
        &request_id,
        start,
        state.agent_tui_manager.list(&session_id),
    )
}

async fn post_agent_tui_start(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.agent_tui_manager.start(&session_id, &request);
    if result.is_ok() {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/agent-tuis",
        &request_id,
        start,
        result,
    )
}

async fn get_agent_tui(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        "/v1/agent-tuis/{id}",
        &request_id,
        start,
        state.agent_tui_manager.get(&tui_id),
    )
}

async fn post_agent_tui_input(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiInputRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/agent-tuis/{id}/input",
        &request_id,
        start,
        state.agent_tui_manager.input(&tui_id, &request),
    )
}

async fn post_agent_tui_resize(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentTuiResizeRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/agent-tuis/{id}/resize",
        &request_id,
        start,
        state.agent_tui_manager.resize(&tui_id, &request),
    )
}

async fn post_agent_tui_stop(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.agent_tui_manager.stop(&tui_id);
    if let Ok(snapshot) = &result {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        service::broadcast_session_snapshot(&state.sender, &snapshot.session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/agent-tuis/{id}/stop",
        &request_id,
        start,
        result,
    )
}

async fn post_agent_tui_ready(
    Path(tui_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/agent-tuis/{id}/ready",
        &request_id,
        start,
        state.agent_tui_manager.signal_ready(&tui_id),
    )
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

async fn post_send_signal(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<SignalSendRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::send_signal(
        &session_id,
        &request,
        db_ref,
        Some(&state.agent_tui_manager),
    );
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/signal",
        &request_id,
        start,
        result,
    )
}

async fn post_cancel_signal(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<SignalCancelRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::cancel_signal(&session_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/signal-cancel",
        &request_id,
        start,
        result,
    )
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

async fn get_codex_runs(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        "/v1/sessions/{id}/codex-runs",
        &request_id,
        start,
        state.codex_controller.list_runs(&session_id),
    )
}

async fn post_codex_run(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<CodexRunRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/codex-runs",
        &request_id,
        start,
        state.codex_controller.start_run(&session_id, &request),
    )
}

async fn get_codex_run(
    Path(run_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "GET",
        "/v1/codex-runs/{id}",
        &request_id,
        start,
        state.codex_controller.run(&run_id),
    )
}

async fn post_codex_steer(
    Path(run_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<CodexSteerRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/codex-runs/{id}/steer",
        &request_id,
        start,
        state.codex_controller.steer(&run_id, &request),
    )
}

async fn post_codex_interrupt(
    Path(run_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/codex-runs/{id}/interrupt",
        &request_id,
        start,
        state.codex_controller.interrupt(&run_id),
    )
}

async fn post_codex_approval(
    Path((run_id, approval_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<CodexApprovalDecisionRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/codex-runs/{id}/approvals/{id}",
        &request_id,
        start,
        state
            .codex_controller
            .resolve_approval(&run_id, &approval_id, &request),
    )
}

async fn post_voice_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<VoiceSessionStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/voice-sessions",
        &request_id,
        start,
        super::voice::start_session(&session_id, &request),
    )
}

async fn post_voice_audio_chunk(
    Path(voice_session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<VoiceAudioChunkRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/voice-sessions/{id}/audio",
        &request_id,
        start,
        super::voice::append_audio_chunk(&voice_session_id, &request).await,
    )
}

async fn post_voice_transcript(
    Path(voice_session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<VoiceTranscriptUpdateRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/voice-sessions/{id}/transcript",
        &request_id,
        start,
        super::voice::append_transcript(&voice_session_id, &request),
    )
}

async fn post_voice_finish(
    Path(voice_session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<VoiceSessionFinishRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    timed_json(
        "POST",
        "/v1/voice-sessions/{id}/finish",
        &request_id,
        start,
        super::voice::finish_session(&voice_session_id, &request),
    )
}

async fn stream_global(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Result<Sse<impl futures_util::Stream<Item = Result<Event, Infallible>>>, Response> {
    require_auth(&headers, &state).map_err(|response| *response)?;
    let mut receiver = state.sender.subscribe();
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let initial_events = service::global_stream_initial_events(db_guard.as_deref());
    drop(db_guard);
    let stream = stream! {
        for event in initial_events {
            let event_name = event.event.clone();
            yield Ok(Event::default().event(&event_name).json_data(event).expect("serialize stream event"));
        }
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let initial_events = service::session_stream_initial_events(&session_id, db_guard.as_deref());
    drop(db_guard);
    let stream = stream! {
        for event in initial_events {
            let event_name = event.event.clone();
            yield Ok(Event::default().event(&event_name).json_data(event).expect("serialize stream event"));
        }
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
    let result = match super::db::ensure_shared_db(&state.db) {
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
        && let Ok(db) = super::db::ensure_shared_db(&state.db)
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
    let result = match super::db::ensure_shared_db(&state.db) {
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
        && let Ok(db) = super::db::ensure_shared_db(&state.db)
    {
        let db_guard = db.lock().expect("db lock");
        service::broadcast_session_snapshot(&state.sender, &session_id, Some(&db_guard));
    }
    timed_json("POST", "/v1/sessions/{id}/join", &request_id, start, result)
}

async fn post_signal_ack(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<SignalAckRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::record_signal_ack_direct(&session_id, &request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
    }
    timed_json(
        "POST",
        "/v1/sessions/{id}/signal-ack",
        &request_id,
        start,
        result.map(|()| serde_json::json!({"ok": true})),
    )
}

fn map_json<T: serde::Serialize>(result: Result<T, CliError>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(error) if error.code() == "SANDBOX001" => {
            let feature = match error.kind() {
                CliErrorKind::Common(common) => common.sandbox_feature().unwrap_or(""),
                _ => "",
            };
            (
                StatusCode::NOT_IMPLEMENTED,
                Json(serde_json::json!({
                    "error": "sandbox-disabled",
                    "feature": feature,
                })),
            )
                .into_response()
        }
        Err(error) if error.code() == "CODEX001" => {
            let endpoint = match error.kind() {
                CliErrorKind::Common(common) => common.codex_endpoint().unwrap_or(""),
                _ => "",
            };
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({
                    "error": "codex-unavailable",
                    "endpoint": endpoint,
                    "hint": "run: harness bridge start",
                })),
            )
                .into_response()
        }
        Err(error) if error.code() == "KSRCLI092" => (
            StatusCode::CONFLICT,
            Json(serde_json::json!({
                "error": {
                    "code": error.code(),
                    "message": error.message(),
                    "details": error.details(),
                }
            })),
        )
            .into_response(),
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

fn timed_json<T: serde::Serialize>(
    method: &str,
    path: &str,
    request_id: &str,
    start: Instant,
    result: Result<T, CliError>,
) -> Response {
    let elapsed = start.elapsed().as_millis();
    let duration_ms = u64::try_from(elapsed).unwrap_or(u64::MAX);
    let status: u16 = match &result {
        Ok(_) => 200,
        Err(error) if error.code() == "SANDBOX001" => 501,
        Err(error) if error.code() == "CODEX001" => 503,
        Err(error) if error.code() == "KSRCLI092" => 409,
        Err(_) => 400,
    };
    log_request(method, path, status, duration_ms, request_id);
    map_json(result)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_request(method: &str, path: &str, status: u16, duration_ms: u64, request_id: &str) {
    tracing::event!(
        request_activity_log_level(),
        method,
        path,
        status,
        duration_ms,
        request_id,
        "daemon request"
    );
}

const fn request_activity_log_level() -> tracing::Level {
    crate::DAEMON_ACTIVITY_LOG_LEVEL
}

fn extract_request_id(headers: &HeaderMap) -> String {
    headers
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_string()
}

pub(super) fn require_auth(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<(), Box<Response>> {
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

#[cfg(test)]
mod tests {
    use super::{
        DaemonHttpState, SessionScopeQuery, StatusCode, authorize_control_request, get_diagnostics,
        get_health, get_timeline, map_json, request_activity_log_level,
    };
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
    use crate::daemon::agent_tui::AgentTuiManagerHandle;
    use crate::daemon::codex_controller::CodexControllerHandle;
    use crate::daemon::db::DaemonDb;
    use crate::daemon::index::DiscoveredProject;
    use crate::daemon::protocol::SessionEndRequest;
    use crate::daemon::state::{DaemonManifest, HostBridgeManifest};
    use crate::errors::CliErrorKind;
    use crate::session::types::CONTROL_PLANE_ACTOR_ID;
    use crate::session::types::{
        AgentRegistration, AgentStatus, SessionMetrics, SessionRole, SessionState, SessionStatus,
    };
    use axum::body::to_bytes;
    use axum::extract::Query;
    use axum::extract::State;
    use axum::http::{HeaderMap, header::AUTHORIZATION};
    use serde_json::Value;
    use std::collections::BTreeMap;
    use std::sync::{Arc, Mutex, OnceLock};
    use tokio::sync::broadcast;

    async fn response_body(result: Result<Value, crate::errors::CliError>) -> (StatusCode, Value) {
        let response = map_json(result);
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 4096).await.expect("body");
        let json: Value = serde_json::from_slice(&bytes).expect("json body");
        (status, json)
    }

    async fn response_json(response: axum::response::Response) -> (StatusCode, Value) {
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 4 * 1024 * 1024)
            .await
            .expect("body");
        let json: Value = serde_json::from_slice(&bytes).expect("json body");
        (status, json)
    }

    fn auth_headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            AUTHORIZATION,
            "Bearer token".parse().expect("authorization header"),
        );
        headers
    }

    fn test_http_state_with_db() -> DaemonHttpState {
        let (sender, _) = broadcast::channel(8);
        let db_slot = Arc::new(OnceLock::new());
        let db = Arc::new(Mutex::new(
            DaemonDb::open_in_memory().expect("open in-memory db"),
        ));
        db_slot.set(db).expect("install db");
        DaemonHttpState {
            token: "token".into(),
            sender: sender.clone(),
            manifest: DaemonManifest {
                version: "20.6.0".into(),
                pid: 1,
                endpoint: "http://127.0.0.1:0".into(),
                started_at: "2026-04-13T00:00:00Z".into(),
                token_path: "/tmp/token".into(),
                sandboxed: false,
                host_bridge: HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
            },
            daemon_epoch: "epoch".into(),
            replay_buffer: Arc::new(Mutex::new(super::super::websocket::ReplayBuffer::new(8))),
            db: db_slot.clone(),
            codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
            agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
        }
    }

    #[tokio::test]
    async fn map_json_maps_codex_unavailable_to_503() {
        let error = CliErrorKind::codex_server_unavailable("ws://127.0.0.1:4500").into();
        let (status, body) = response_body(Err(error)).await;

        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"], "codex-unavailable");
        assert_eq!(body["endpoint"], "ws://127.0.0.1:4500");
        assert_eq!(body["hint"], "run: harness bridge start");
    }

    #[test]
    fn request_logging_uses_debug_activity_level() {
        assert_eq!(request_activity_log_level(), tracing::Level::DEBUG);
    }

    #[tokio::test]
    async fn map_json_maps_sandbox_disabled_to_501() {
        let error = CliErrorKind::sandbox_feature_disabled("codex.stdio").into();
        let (status, body) = response_body(Err(error)).await;

        assert_eq!(status, StatusCode::NOT_IMPLEMENTED);
        assert_eq!(body["error"], "sandbox-disabled");
        assert_eq!(body["feature"], "codex.stdio");
    }

    #[tokio::test]
    async fn map_json_maps_other_errors_to_400() {
        let error = CliErrorKind::workflow_parse("bad request").into();
        let (status, body) = response_body(Err(error)).await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(body["error"]["code"].as_str().is_some());
    }

    #[tokio::test]
    async fn map_json_maps_session_agent_conflict_to_409() {
        let error = CliErrorKind::session_agent_conflict("agent-tui still active").into();
        let (status, body) = response_body(Err(error)).await;

        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(body["error"]["code"], "KSRCLI092");
    }

    #[tokio::test]
    async fn get_health_requires_auth() {
        let response = get_health(HeaderMap::new(), State(test_http_state_with_db())).await;

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn get_health_responds_when_db_lock_is_held() {
        let state = test_http_state_with_db();
        let db = state.db.get().expect("db slot").clone();
        let _db_guard = db.lock().expect("db lock");

        let response = get_health(auth_headers(), State(state)).await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn get_diagnostics_responds_when_db_lock_is_held() {
        let state = test_http_state_with_db();
        let db = state.db.get().expect("db slot").clone();
        let _db_guard = db.lock().expect("db lock");

        let response = get_diagnostics(auth_headers(), State(state)).await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn get_timeline_summary_scope_returns_window_metadata() {
        let state = test_http_state_with_db();
        let db = state.db.get().expect("db slot").clone();
        {
            let db = db.lock().expect("db lock");
            let project = sample_project();
            db.sync_project(&project).expect("sync project");
            db.save_session_state(&project.project_id, &sample_session_state())
                .expect("save session state");
            db.sync_conversation_events(
                "sess-test-1",
                "codex-worker",
                "codex",
                &[sample_tool_result_event()],
            )
            .expect("sync conversation events");
        }

        let response = get_timeline(
            axum::extract::Path("sess-test-1".to_owned()),
            Query(SessionScopeQuery {
                scope: Some("summary".into()),
                ..SessionScopeQuery::default()
            }),
            auth_headers(),
            State(state),
        )
        .await;

        let (status, body) = response_json(response).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["revision"].as_i64(), Some(1));
        assert_eq!(body["total_count"].as_u64(), Some(1));
        assert_eq!(body["unchanged"].as_bool(), Some(false));
        let Value::Array(entries) = body["entries"].clone() else {
            panic!("expected timeline entries array response");
        };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["kind"].as_str(), Some("tool_result"));
        assert_eq!(
            entries[0]["summary"].as_str(),
            Some("codex-worker received a result from Bash")
        );
        assert_eq!(entries[0]["payload"], serde_json::json!({}));
    }

    #[test]
    fn authorize_control_request_rebinds_client_actor() {
        let state = test_http_state_with_db();
        let mut request = SessionEndRequest {
            actor: "spoofed-leader".into(),
        };

        authorize_control_request(&auth_headers(), &state, &mut request)
            .expect("authorize request");

        assert_eq!(request.actor, CONTROL_PLANE_ACTOR_ID);
    }

    fn sample_project() -> DiscoveredProject {
        DiscoveredProject {
            project_id: "project-abc123".into(),
            name: "harness".into(),
            project_dir: Some("/tmp/harness".into()),
            repository_root: Some("/tmp/harness".into()),
            checkout_id: "checkout-abc123".into(),
            checkout_name: "Repository".into(),
            context_root: "/tmp/data/projects/project-abc123".into(),
            is_worktree: false,
            worktree_name: None,
        }
    }

    fn sample_session_state() -> SessionState {
        let mut agents = BTreeMap::new();
        agents.insert(
            "codex-worker".into(),
            AgentRegistration {
                agent_id: "codex-worker".into(),
                name: "Codex Worker".into(),
                runtime: "codex".into(),
                role: SessionRole::Worker,
                capabilities: vec!["general".into()],
                joined_at: "2026-04-13T19:00:00Z".into(),
                updated_at: "2026-04-13T19:00:00Z".into(),
                status: AgentStatus::Active,
                agent_session_id: None,
                last_activity_at: Some("2026-04-13T19:00:00Z".into()),
                current_task_id: None,
                runtime_capabilities: RuntimeCapabilities::default(),
                persona: None,
            },
        );

        SessionState {
            schema_version: 3,
            state_version: 1,
            session_id: "sess-test-1".into(),
            title: "sess-test-1".into(),
            context: "http timeline scope fixture".into(),
            status: SessionStatus::Active,
            created_at: "2026-04-13T19:00:00Z".into(),
            updated_at: "2026-04-13T19:00:00Z".into(),
            agents,
            tasks: BTreeMap::new(),
            leader_id: None,
            archived_at: None,
            last_activity_at: Some("2026-04-13T19:00:00Z".into()),
            observe_id: None,
            pending_leader_transfer: None,
            metrics: SessionMetrics::default(),
        }
    }

    fn sample_tool_result_event() -> ConversationEvent {
        ConversationEvent {
            timestamp: Some("2026-04-13T19:02:00Z".into()),
            sequence: 1,
            kind: ConversationEventKind::ToolResult {
                tool_name: "Bash".into(),
                invocation_id: Some("call-bash-1".into()),
                output: serde_json::json!({
                    "stdout": "x".repeat(8_192),
                    "exit_code": 0,
                }),
                is_error: false,
                duration_ms: Some(125),
            },
            agent: "codex-worker".into(),
            session_id: "sess-test-1".into(),
        }
    }
}
