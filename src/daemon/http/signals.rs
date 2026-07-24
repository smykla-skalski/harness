use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::Json;
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

use crate::daemon::protocol::{
    SessionDetail, SignalAckRequest, SignalCancelRequest, SignalSendRequest, http_paths,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::DaemonHttpState;
use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};

use super::openapi::{DaemonErrorBody, OkResponse};

pub(super) fn signal_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(post_send_signal))
        .routes(routes!(post_cancel_signal))
        .routes(routes!(post_signal_ack))
}

#[utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/signal",
    tag = "sessions",
    params(("session_id" = String, Path, description = "Session identifier")),
    request_body = SignalSendRequest,
    responses(
        (status = 200, description = "Signal delivered; updated session detail", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_send_signal(
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
    let result = send_signal_response(&state, &session_id, &request).await;
    timed_json(
        "POST",
        http_paths::SESSION_SIGNAL_SEND,
        &request_id,
        start,
        result,
    )
}

async fn send_signal_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &SignalSendRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result = service::send_signal_async(
            session_id,
            request,
            async_db.as_ref(),
            Some(&state.agent_tui_manager),
        )
        .await;
        if result.is_ok() {
            service::broadcast_session_snapshot_async(
                &state.sender,
                session_id,
                Some(async_db.as_ref()),
            )
            .await;
        }
        return result;
    }

    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::send_signal(session_id, request, db_ref, Some(&state.agent_tui_manager));
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, session_id, db_ref);
    }
    result
}

#[utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/signal-cancel",
    tag = "sessions",
    params(("session_id" = String, Path, description = "Session identifier")),
    request_body = SignalCancelRequest,
    responses(
        (status = 200, description = "Signal cancelled; updated session detail", body = SessionDetail),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_cancel_signal(
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
    let result = cancel_signal_response(&state, &session_id, &request).await;
    timed_json(
        "POST",
        http_paths::SESSION_SIGNAL_CANCEL,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/sessions/{session_id}/signal-ack",
    tag = "sessions",
    params(("session_id" = String, Path, description = "Session identifier")),
    request_body = SignalAckRequest,
    responses(
        (status = 200, description = "Signal acknowledgment recorded", body = OkResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_signal_ack(
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
    let result = signal_ack_response(&state, &session_id, &request).await;
    timed_json(
        "POST",
        http_paths::SESSION_SIGNAL_ACK,
        &request_id,
        start,
        result.map(|()| serde_json::json!({"ok": true})),
    )
}

async fn cancel_signal_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &SignalCancelRequest,
) -> Result<SessionDetail, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result = service::cancel_signal_async(session_id, request, async_db.as_ref()).await;
        if result.is_ok() {
            service::broadcast_session_snapshot_async(
                &state.sender,
                session_id,
                Some(async_db.as_ref()),
            )
            .await;
        }
        return result;
    }

    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::cancel_signal(session_id, request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, session_id, db_ref);
    }
    result
}

async fn signal_ack_response(
    state: &DaemonHttpState,
    session_id: &str,
    request: &SignalAckRequest,
) -> Result<(), CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result =
            service::record_signal_ack_direct_async(session_id, request, async_db.as_ref()).await;
        if result.is_ok() {
            service::broadcast_session_snapshot_async(
                &state.sender,
                session_id,
                Some(async_db.as_ref()),
            )
            .await;
        }
        return result;
    }

    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::record_signal_ack_direct(session_id, request, db_ref);
    if result.is_ok() {
        service::broadcast_session_snapshot(&state.sender, session_id, db_ref);
    }
    result
}
