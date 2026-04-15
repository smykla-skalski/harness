use std::time::Instant;

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::routing::post;
use axum::{Json, Router};

use crate::daemon::protocol::{
    SessionDetail, SignalAckRequest, SignalCancelRequest, SignalSendRequest,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::DaemonHttpState;
use super::auth::{authorize_control_request, require_auth};
use super::response::{extract_request_id, timed_json};

pub(super) fn signal_routes() -> Router<DaemonHttpState> {
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
        "/v1/sessions/{id}/signal-cancel",
        &request_id,
        start,
        result,
    )
}

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
        "/v1/sessions/{id}/signal-ack",
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
