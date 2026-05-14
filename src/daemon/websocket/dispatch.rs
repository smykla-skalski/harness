use super::connection::ConnectionState;
use super::frames::{error_response, serialize_error_response_frames, serialize_response_frames};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{WsRequest, WsResponse};
use crate::telemetry::{
    TelemetryBaggage, apply_parent_context_from_text_map, current_trace_id, with_active_baggage,
};
use axum::extract::ws::Message;
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

async fn dispatch_inner(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    if let Some(response) = routing::dispatch_known_method(request, state, connection).await {
        return response;
    }
    error_response(
        &request.id,
        "UNKNOWN_METHOD",
        &format!("unknown method: {}", request.method),
    )
}

#[cfg(test)]
mod tests;
