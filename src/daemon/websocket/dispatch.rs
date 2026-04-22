use super::connection::ConnectionState;
use super::frames::{
    error_response, ok_response, serialize_error_response_frames, serialize_response_frames,
};
use super::mutations::{
    dispatch_mutation_prefer_async, dispatch_mutation_with_agent_prefer_async,
    dispatch_mutation_with_task_prefer_async, dispatch_session_start, dispatch_set_log_level,
};
use super::queries::{
    dispatch_read_query, handle_session_subscribe, handle_session_unsubscribe,
    handle_stream_subscribe, handle_stream_unsubscribe,
};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, ObserveSessionRequest, RoleChangeRequest,
    SessionEndRequest, SignalCancelRequest, SignalSendRequest, TaskAssignRequest,
    TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest, TaskQueuePolicyRequest,
    TaskUpdateRequest, WsRequest, WsResponse,
};
use crate::daemon::service;
use crate::telemetry::{
    TelemetryBaggage, apply_parent_context_from_text_map, current_trace_id, with_active_baggage,
};
use axum::extract::ws::Message;
use std::sync::{Arc, Mutex};
use tokio::time::Instant;
use tracing::Instrument as _;
use tracing::field::{Empty, display};

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
    tracing::event!(
        ws_activity_log_level(),
        method = %request.method,
        request_id = %request.id,
        duration_ms,
        is_error,
        "ws dispatch"
    );
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
    if let Some(response) = dispatch_known_method(request, state, connection).await {
        return response;
    }
    unknown_method_response(&request.id, &request.method)
}

async fn dispatch_known_method(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_core_method(request, state, connection).await {
        return Some(response);
    }
    if let Some(response) = dispatch_task_mutation(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_agent_mutation(request, state).await {
        return Some(response);
    }
    dispatch_session_mutation(request, state).await
}

async fn dispatch_core_method(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_misc_method(request, state, connection).await {
        return Some(response);
    }
    dispatch_read_method(request, state).await
}

async fn dispatch_misc_method(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<WsResponse> {
    match request.method.as_str() {
        "ping" => Some(ok_response(
            &request.id,
            serde_json::json!({ "pong": true }),
        )),
        "daemon.set_log_level" => Some(dispatch_set_log_level(request, state)),
        "session.subscribe" => Some(handle_session_subscribe(request, state, connection).await),
        "session.unsubscribe" => Some(handle_session_unsubscribe(request, connection)),
        "stream.subscribe" => Some(handle_stream_subscribe(request, state, connection).await),
        "stream.unsubscribe" => Some(handle_stream_unsubscribe(request, connection)),
        _ => None,
    }
}

async fn dispatch_read_method(request: &WsRequest, state: &DaemonHttpState) -> Option<WsResponse> {
    if matches!(
        request.method.as_str(),
        "health"
            | "diagnostics"
            | "daemon.stop"
            | "daemon.log_level"
            | "projects"
            | "sessions"
            | "session.detail"
            | "session.timeline"
            | "session.managed_agents"
            | "managed_agent.detail"
    ) {
        Some(dispatch_read_query(request, state).await)
    } else {
        None
    }
}

async fn dispatch_task_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_task_work_mutation(request, state).await {
        return Some(response);
    }
    dispatch_task_lifecycle_mutation(request, state).await
}

async fn dispatch_task_work_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        "task.create" => Some(dispatch_task_create(request, state).await),
        "task.assign" => Some(dispatch_task_assign(request, state).await),
        "task.checkpoint" => Some(dispatch_task_checkpoint(request, state).await),
        _ => None,
    }
}

async fn dispatch_task_lifecycle_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        "task.drop" => Some(dispatch_task_drop(request, state).await),
        "task.queue_policy" => Some(dispatch_task_queue_policy(request, state).await),
        "task.update" => Some(dispatch_task_update(request, state).await),
        _ => None,
    }
}
async fn dispatch_agent_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        "agent.change_role" => Some(dispatch_agent_change_role(request, state).await),
        "agent.remove" => Some(dispatch_agent_remove(request, state).await),
        _ => None,
    }
}

async fn dispatch_session_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_session_control_mutation(request, state).await {
        return Some(response);
    }
    dispatch_session_signal_mutation(request, state).await
}

async fn dispatch_session_control_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        "session.start" => Some(dispatch_session_start(request, state).await),
        "leader.transfer" => Some(dispatch_leader_transfer(request, state).await),
        "session.end" => Some(dispatch_session_end(request, state).await),
        _ => None,
    }
}

async fn dispatch_session_signal_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        "signal.send" => Some(dispatch_signal_send(request, state).await),
        "signal.cancel" => Some(dispatch_signal_cancel(request, state).await),
        "session.observe" => Some(dispatch_session_observe(request, state).await),
        _ => None,
    }
}
async fn dispatch_task_create(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: TaskCreateRequest = serde_json::from_value(params)?;
            service::create_task(&session_id, &body, db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: TaskCreateRequest = serde_json::from_value(params)?;
            service::create_task_async(&session_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_task_assign(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskAssignRequest = serde_json::from_value(params)?;
            service::assign_task(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskAssignRequest = serde_json::from_value(params)?;
            service::assign_task_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_task_drop(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskDropRequest = serde_json::from_value(params)?;
            service::drop_task(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskDropRequest = serde_json::from_value(params)?;
            service::drop_task_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_task_queue_policy(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskQueuePolicyRequest = serde_json::from_value(params)?;
            service::update_task_queue_policy(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskQueuePolicyRequest = serde_json::from_value(params)?;
            service::update_task_queue_policy_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_task_update(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskUpdateRequest = serde_json::from_value(params)?;
            service::update_task(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskUpdateRequest = serde_json::from_value(params)?;
            service::update_task_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_task_checkpoint(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskCheckpointRequest = serde_json::from_value(params)?;
            service::checkpoint_task(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskCheckpointRequest = serde_json::from_value(params)?;
            service::checkpoint_task_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_agent_change_role(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_with_agent_prefer_async(
        request,
        state,
        |session_id, agent_id, params, db| {
            let body: RoleChangeRequest = serde_json::from_value(params)?;
            service::change_role(&session_id, &agent_id, &body, db).map_err(Into::into)
        },
        |session_id, agent_id, params, async_db| async move {
            let body: RoleChangeRequest = serde_json::from_value(params)?;
            service::change_role_async(&session_id, &agent_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_agent_remove(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_with_agent_prefer_async(
        request,
        state,
        |session_id, agent_id, params, db| {
            let body: AgentRemoveRequest = serde_json::from_value(params)?;
            service::remove_agent(&session_id, &agent_id, &body, db).map_err(Into::into)
        },
        |session_id, agent_id, params, async_db| async move {
            let body: AgentRemoveRequest = serde_json::from_value(params)?;
            service::remove_agent_async(&session_id, &agent_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_leader_transfer(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: LeaderTransferRequest = serde_json::from_value(params)?;
            service::transfer_leader(&session_id, &body, db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: LeaderTransferRequest = serde_json::from_value(params)?;
            service::transfer_leader_async(&session_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_session_end(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: SessionEndRequest = serde_json::from_value(params)?;
            service::end_session(&session_id, &body, db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: SessionEndRequest = serde_json::from_value(params)?;
            service::end_session_async(&session_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_signal_send(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: SignalSendRequest = serde_json::from_value(params)?;
            service::send_signal(&session_id, &body, db, Some(&state.agent_tui_manager))
                .map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: SignalSendRequest = serde_json::from_value(params)?;
            service::send_signal_async(
                &session_id,
                &body,
                &async_db,
                Some(&state.agent_tui_manager),
            )
            .await
            .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_signal_cancel(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: SignalCancelRequest = serde_json::from_value(params)?;
            service::cancel_signal(&session_id, &body, db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: SignalCancelRequest = serde_json::from_value(params)?;
            service::cancel_signal_async(&session_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

async fn dispatch_session_observe(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: ObserveSessionRequest = serde_json::from_value(params)?;
            service::observe_session(&session_id, Some(&body), db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: ObserveSessionRequest = serde_json::from_value(params)?;
            service::observe_session_async(&session_id, Some(&body), &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

fn unknown_method_response(request_id: &str, method: &str) -> WsResponse {
    error_response(
        request_id,
        "UNKNOWN_METHOD",
        &format!("unknown method: {method}"),
    )
}

#[cfg(test)]
mod tests;
