use super::connection::ConnectionState;
use super::frames::{
    error_response, error_response_with_payload, serialize_error_response_frames,
    serialize_response_frames,
};
use crate::daemon::http::{DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::protocol::{
    WsErrorPayload, WsRequest, WsResponse, with_control_plane_actor, ws_methods,
};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_auth::{
    RemoteAuthError, authorize_remote_ws_method, remote_ws_required_scope,
};
use crate::daemon::remote_identity::RemoteStoredClient;
use crate::daemon::remote_request_audit::RemoteAuthorizationAudit;
use crate::errors::CliError;
use crate::telemetry::{
    TelemetryBaggage, apply_parent_context_from_text_map, current_trace_id, with_active_baggage,
};
use axum::extract::ws::Message;
use std::future::Future;
use std::sync::{Arc, Mutex};
use tokio::time::Instant;
use tracing::Instrument as _;
use tracing::field::{Empty, display};

mod mutation_handlers;
mod routing;

pub(crate) async fn handle_message(
    text: &str,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Vec<Message> {
    let request: WsRequest = match serde_json::from_str(text) {
        Ok(request) => request,
        Err(error) => {
            return serialize_error_response_frames(
                None,
                "MALFORMED_MESSAGE",
                &format!("failed to parse message: {error}"),
            );
        }
    };

    let response = Box::pin(dispatch(&request, state, connection)).await;
    serialize_response_frames(&response).unwrap_or_else(|error| {
        serialize_error_response_frames(
            Some(&request.id),
            "SERIALIZE_ERROR",
            &format!("failed to serialize response: {error}"),
        )
    })
}

pub(crate) fn handle_overloaded_message(
    text: &str,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
    status: u16,
    message: &str,
) -> Vec<Message> {
    let request: WsRequest = match serde_json::from_str(text) {
        Ok(request) => request,
        Err(error) => {
            return serialize_error_response_frames(
                None,
                "MALFORMED_MESSAGE",
                &format!("failed to parse message: {error}"),
            );
        }
    };
    if let Err(response) = authorize_remote_ws_request(&request, state, connection) {
        return serialize_response_frames(&response).unwrap_or_else(|_| {
            serialize_error_response_frames(
                Some(&request.id),
                "SERIALIZE_ERROR",
                "failed to serialize remote authorization response",
            )
        });
    }
    let response = error_response_with_payload(
        &request.id,
        WsErrorPayload {
            code: "REMOTE_LIMITS".to_string(),
            message: message.to_string(),
            details: Vec::new(),
            status_code: Some(status),
            data: None,
        },
    );
    serialize_response_frames(&response).unwrap_or_else(|_| {
        serialize_error_response_frames(
            Some(&request.id),
            "SERIALIZE_ERROR",
            "failed to serialize remote limit response",
        )
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) async fn dispatch(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let start = Instant::now();
    let span = tracing::info_span!(
        parent: None,
        "daemon.websocket.rpc",
        otel.name = %request.method,
        otel.kind = "server",
        "rpc.system" = "harness-daemon",
        "rpc.method" = %request.method,
        "transport.kind" = "websocket",
        request_id = %request.id,
        duration_ms = Empty,
        is_error = Empty,
        "request.failed" = Empty,
        trace_id = Empty
    );
    let baggage = request
        .trace_context
        .as_ref()
        .map_or_else(TelemetryBaggage::default, |trace_context| {
            apply_parent_context_from_text_map(&span, trace_context)
        });
    if let Some(trace_id) = span.in_scope(current_trace_id) {
        span.record("trace_id", display(trace_id));
    }
    let response = Box::pin(with_active_baggage(
        baggage,
        dispatch_inner(request, state, connection).instrument(span.clone()),
    ))
    .await;
    let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    let is_error = response.error.is_some();
    span.record("duration_ms", display(duration_ms));
    span.record("is_error", display(is_error));
    span.record("request.failed", display(is_error));
    if let Some(error) = response.error.as_ref() {
        tracing::warn!(
            method = %request.method,
            request_id = %request.id,
            duration_ms,
            error.code = %error.code,
            error.message = %error.message,
            "ws dispatch failed"
        );
    } else {
        tracing::event!(
            ws_activity_log_level(),
            method = %request.method,
            request_id = %request.id,
            duration_ms,
            is_error,
            "ws dispatch"
        );
    }
    response
}

pub(crate) const fn ws_activity_log_level() -> tracing::Level {
    crate::DAEMON_ACTIVITY_LOG_LEVEL
}

#[expect(
    clippy::large_futures,
    reason = "boxing dispatch would allocate for every websocket message"
)]
async fn dispatch_inner(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    if let Err(response) = authorize_remote_ws_request(request, state, connection) {
        return *response;
    }
    if let Some(response) = with_connection_actor(
        state,
        connection,
        routing::dispatch_known_method(request, state, connection),
    )
    .await
    {
        return response;
    }
    error_response(
        &request.id,
        "UNKNOWN_METHOD",
        &format!("unknown method: {}", request.method),
    )
}

async fn with_connection_actor<T>(
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
    future: impl Future<Output = T>,
) -> T {
    let actor = (state.auth_mode == DaemonHttpAuthMode::Remote)
        .then(|| remote_client_for_connection(connection))
        .flatten()
        .map(|client| client.control_plane_actor_id());
    if let Some(actor) = actor {
        with_control_plane_actor(actor, future).await
    } else {
        future.await
    }
}

fn authorize_remote_ws_request(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Result<(), Box<WsResponse>> {
    if state.auth_mode == DaemonHttpAuthMode::Local || !is_declared_ws_method(&request.method) {
        return Ok(());
    }
    let required_scope = remote_ws_required_scope(&request.method)
        .map_err(|error| Box::new(remote_ws_auth_error_response(&request.id, error)))?;
    let (client, remote_addr) = remote_connection_identity(connection);
    let Some(client) = client else {
        let error = RemoteAuthError::MissingClientId;
        record_remote_ws_denial(
            request,
            state,
            None,
            required_scope,
            remote_addr.as_deref(),
            error,
        )?;
        return Err(Box::new(remote_ws_auth_error_response(&request.id, error)));
    };
    match authorize_remote_ws_method(&client, &request.method) {
        Ok(decision) => RemoteAuthorizationAudit::allowed(
            &request.id,
            &client.client_id,
            &request.method,
            decision.required_scope,
            remote_addr.as_deref(),
        )
        .record(state.db.get())
        .map(|_| ())
        .map_err(|error| remote_ws_audit_error_response(request, &error)),
        Err(error) => {
            record_remote_ws_denial(
                request,
                state,
                Some(&client.client_id),
                required_scope,
                remote_addr.as_deref(),
                error,
            )?;
            Err(Box::new(remote_ws_auth_error_response(&request.id, error)))
        }
    }
}

fn is_declared_ws_method(method: &str) -> bool {
    ws_methods::ALL.contains(&method)
}

fn remote_client_for_connection(
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<RemoteStoredClient> {
    remote_connection_identity(connection).0
}

fn remote_connection_identity(
    connection: &Arc<Mutex<ConnectionState>>,
) -> (Option<RemoteStoredClient>, Option<String>) {
    let connection = connection.lock().expect("connection lock");
    (
        connection.remote_client().cloned(),
        connection.remote_addr().map(ToOwned::to_owned),
    )
}

fn record_remote_ws_denial(
    request: &WsRequest,
    state: &DaemonHttpState,
    client_id: Option<&str>,
    required_scope: RemoteAccessScope,
    remote_addr: Option<&str>,
    error: RemoteAuthError,
) -> Result<(), Box<WsResponse>> {
    RemoteAuthorizationAudit::denied(
        &request.id,
        client_id,
        &request.method,
        required_scope,
        remote_addr,
        &error.to_string(),
    )
    .record(state.db.get())
    .map(|_| ())
    .map_err(|audit_error| remote_ws_audit_error_response(request, &audit_error))
}

fn remote_ws_audit_error_response(request: &WsRequest, error: &CliError) -> Box<WsResponse> {
    log_remote_ws_audit_error(request, error);
    Box::new(error_response_with_payload(
        &request.id,
        WsErrorPayload {
            code: "REMOTE_AUDIT".to_string(),
            message: "remote authorization audit is unavailable".to_string(),
            details: Vec::new(),
            status_code: Some(503),
            data: None,
        },
    ))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_remote_ws_audit_error(request: &WsRequest, error: &CliError) {
    tracing::error!(
        error = %error,
        method = %request.method,
        request_id = %request.id,
        "remote websocket authorization audit failed"
    );
}

fn remote_ws_auth_error_response(request_id: &str, error: RemoteAuthError) -> WsResponse {
    error_response_with_payload(
        request_id,
        WsErrorPayload {
            code: "REMOTE_AUTH".to_string(),
            message: error.to_string(),
            details: Vec::new(),
            status_code: Some(error.status_code().as_u16()),
            data: None,
        },
    )
}

#[cfg(test)]
mod tests;
