use std::sync::{Arc, Mutex};

use axum::extract::ws::Message;
use tokio::time::Instant;

use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, ObserveSessionRequest, RoleChangeRequest,
    SessionEndRequest, SetLogLevelRequest, SignalCancelRequest, SignalSendRequest,
    TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest,
    TaskQueuePolicyRequest, TaskUpdateRequest, WsRequest, WsResponse,
};
use crate::daemon::service;

use super::connection::ConnectionState;
use super::frames::{
    error_response, ok_response, serialize_error_response_frames, serialize_response_frames,
};
use super::mutations::{
    dispatch_mutation, dispatch_mutation_with_agent, dispatch_mutation_with_task, dispatch_query,
};
use super::queries::{
    dispatch_read_query, handle_session_subscribe, handle_session_unsubscribe,
    handle_stream_subscribe, handle_stream_unsubscribe,
};

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

    let response = dispatch(&request, state, connection).await;
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
    let response = dispatch_inner(request, state, connection).await;
    let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    let is_error = response.error.is_some();
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
    match request.method.as_str() {
        "ping" => ok_response(&request.id, serde_json::json!({ "pong": true })),
        "health" | "diagnostics" | "daemon.stop" | "daemon.log_level" | "projects" | "sessions"
        | "session.detail" | "session.timeline" | "session.agent_tuis" | "agent_tui.detail" => {
            dispatch_read_query(request, state).await
        }
        "daemon.set_log_level" => {
            let body: SetLogLevelRequest = match serde_json::from_value(request.params.clone()) {
                Ok(body) => body,
                Err(error) => {
                    return error_response(
                        &request.id,
                        "INVALID_PARAMS",
                        &format!("invalid set_log_level params: {error}"),
                    );
                }
            };
            dispatch_query(&request.id, || service::set_log_level(&body, &state.sender))
        }
        "session.subscribe" => handle_session_subscribe(request, state, connection).await,
        "session.unsubscribe" => handle_session_unsubscribe(request, connection),
        "stream.subscribe" => handle_stream_subscribe(request, state, connection),
        "stream.unsubscribe" => handle_stream_unsubscribe(request, connection),
        "task.create" => dispatch_mutation(request, state, |session_id, params, db| {
            let body: TaskCreateRequest = serde_json::from_value(params)?;
            service::create_task(&session_id, &body, db).map_err(Into::into)
        }),
        "task.assign" => {
            dispatch_mutation_with_task(request, state, |session_id, task_id, params, db| {
                let body: TaskAssignRequest = serde_json::from_value(params)?;
                service::assign_task(&session_id, &task_id, &body, db).map_err(Into::into)
            })
        }
        "task.drop" => {
            dispatch_mutation_with_task(request, state, |session_id, task_id, params, db| {
                let body: TaskDropRequest = serde_json::from_value(params)?;
                service::drop_task(&session_id, &task_id, &body, db).map_err(Into::into)
            })
        }
        "task.queue_policy" => {
            dispatch_mutation_with_task(request, state, |session_id, task_id, params, db| {
                let body: TaskQueuePolicyRequest = serde_json::from_value(params)?;
                service::update_task_queue_policy(&session_id, &task_id, &body, db)
                    .map_err(Into::into)
            })
        }
        "task.update" => {
            dispatch_mutation_with_task(request, state, |session_id, task_id, params, db| {
                let body: TaskUpdateRequest = serde_json::from_value(params)?;
                service::update_task(&session_id, &task_id, &body, db).map_err(Into::into)
            })
        }
        "task.checkpoint" => {
            dispatch_mutation_with_task(request, state, |session_id, task_id, params, db| {
                let body: TaskCheckpointRequest = serde_json::from_value(params)?;
                service::checkpoint_task(&session_id, &task_id, &body, db).map_err(Into::into)
            })
        }
        "agent.change_role" => {
            dispatch_mutation_with_agent(request, state, |session_id, agent_id, params, db| {
                let body: RoleChangeRequest = serde_json::from_value(params)?;
                service::change_role(&session_id, &agent_id, &body, db).map_err(Into::into)
            })
        }
        "agent.remove" => {
            dispatch_mutation_with_agent(request, state, |session_id, agent_id, params, db| {
                let body: AgentRemoveRequest = serde_json::from_value(params)?;
                service::remove_agent(&session_id, &agent_id, &body, db).map_err(Into::into)
            })
        }
        "leader.transfer" => dispatch_mutation(request, state, |session_id, params, db| {
            let body: LeaderTransferRequest = serde_json::from_value(params)?;
            service::transfer_leader(&session_id, &body, db).map_err(Into::into)
        }),
        "session.end" => dispatch_mutation(request, state, |session_id, params, db| {
            let body: SessionEndRequest = serde_json::from_value(params)?;
            service::end_session(&session_id, &body, db).map_err(Into::into)
        }),
        "signal.send" => dispatch_mutation(request, state, |session_id, params, db| {
            let body: SignalSendRequest = serde_json::from_value(params)?;
            service::send_signal(&session_id, &body, db, Some(&state.agent_tui_manager))
                .map_err(Into::into)
        }),
        "signal.cancel" => dispatch_mutation(request, state, |session_id, params, db| {
            let body: SignalCancelRequest = serde_json::from_value(params)?;
            service::cancel_signal(&session_id, &body, db).map_err(Into::into)
        }),
        "session.observe" => dispatch_mutation(request, state, |session_id, params, db| {
            let body: ObserveSessionRequest = serde_json::from_value(params)?;
            service::observe_session(&session_id, Some(&body), db).map_err(Into::into)
        }),
        unknown => error_response(
            &request.id,
            "UNKNOWN_METHOD",
            &format!("unknown method: {unknown}"),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::protocol::WsRequest;

    #[test]
    fn websocket_activity_logging_uses_debug_level() {
        assert_eq!(ws_activity_log_level(), tracing::Level::DEBUG);
    }

    #[test]
    fn ws_request_deserialization() {
        let json = r#"{"id":"abc-123","method":"health","params":{}}"#;
        let request: WsRequest = serde_json::from_str(json).expect("deserialize");
        assert_eq!(request.id, "abc-123");
        assert_eq!(request.method, "health");
    }
}
