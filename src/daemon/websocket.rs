use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::{broadcast, mpsc};
use tokio::time::{Instant, interval as tokio_interval};
use tracing::{debug, info};

use crate::errors::CliError;

use super::http::DaemonHttpState;
use super::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, ObserveSessionRequest, RoleChangeRequest,
    SessionEndRequest, SignalSendRequest, StreamEvent, TaskAssignRequest, TaskCheckpointRequest,
    TaskCreateRequest, TaskUpdateRequest, WsErrorPayload, WsPushEvent, WsRequest, WsResponse,
};
use super::service;

/// Bounded replay buffer for reconnecting clients.
#[derive(Debug)]
pub struct ReplayBuffer {
    entries: VecDeque<(u64, String)>,
    capacity: usize,
    next_seq: u64,
}

impl ReplayBuffer {
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            entries: VecDeque::with_capacity(capacity),
            capacity,
            next_seq: 1,
        }
    }

    pub fn append(&mut self, serialized: String) -> u64 {
        let seq = self.next_seq;
        self.next_seq += 1;
        if self.entries.len() >= self.capacity {
            self.entries.pop_front();
        }
        self.entries.push_back((seq, serialized));
        seq
    }

    #[must_use]
    pub fn replay_since(&self, last_seq: u64) -> Option<Vec<(u64, String)>> {
        let oldest = self.entries.front().map(|(seq, _)| *seq)?;
        if last_seq < oldest.saturating_sub(1) {
            return None;
        }
        Some(
            self.entries
                .iter()
                .filter(|(seq, _)| *seq > last_seq)
                .cloned()
                .collect(),
        )
    }

    #[must_use]
    pub fn current_seq(&self) -> u64 {
        self.next_seq.saturating_sub(1)
    }
}

struct ConnectionState {
    global_subscription: bool,
    session_subscriptions: HashSet<String>,
}

impl ConnectionState {
    fn new() -> Self {
        Self {
            global_subscription: false,
            session_subscriptions: HashSet::new(),
        }
    }

    fn should_relay(&self, event: &StreamEvent) -> bool {
        if self.global_subscription {
            return true;
        }
        if let Some(session_id) = &event.session_id {
            return self.session_subscriptions.contains(session_id);
        }
        false
    }
}

pub async fn ws_upgrade_handler(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    ws: WebSocketUpgrade,
) -> Response {
    if let Err(response) = super::http::require_auth(&headers, &state) {
        return *response;
    }
    ws.on_upgrade(move |socket| handle_connection(socket, state))
}

async fn handle_connection(socket: WebSocket, state: DaemonHttpState) {
    let (mut sender, mut receiver) = socket.split();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let (outbound_tx, mut outbound_rx) = mpsc::channel::<String>(256);
    let broadcast_rx = state.sender.subscribe();

    let outbound_tx_relay = outbound_tx.clone();
    let connection_relay = Arc::clone(&connection);
    let replay_buffer = Arc::clone(&state.replay_buffer);
    let relay_task = tokio::spawn(relay_broadcast(
        broadcast_rx,
        outbound_tx_relay,
        connection_relay,
        replay_buffer,
    ));

    let outbound_tx_dispatch = outbound_tx.clone();
    let connection_dispatch = Arc::clone(&connection);
    let inbound_task = tokio::spawn(async move {
        let mut last_client_message = Instant::now();
        let mut idle_check = tokio_interval(Duration::from_secs(15));

        loop {
            tokio::select! {
                message = receiver.next() => {
                    match message {
                        Some(Ok(Message::Text(text))) => {
                            last_client_message = Instant::now();
                            let response = handle_message(
                                &text,
                                &state,
                                &connection_dispatch,
                            );
                            if outbound_tx_dispatch.send(response).await.is_err() {
                                break;
                            }
                        }
                        Some(Ok(Message::Close(_))) | None => break,
                        Some(Err(error)) => {
                            debug!(%error, "websocket receive error");
                            break;
                        }
                        _ => {}
                    }
                }
                _ = idle_check.tick() => {
                    if last_client_message.elapsed() > Duration::from_secs(45) {
                        info!("websocket idle timeout, closing connection");
                        break;
                    }
                }
            }
        }
    });

    let writer_task = tokio::spawn(async move {
        while let Some(text) = outbound_rx.recv().await {
            if sender.send(Message::text(text)).await.is_err() {
                break;
            }
        }
        let _ = sender.close().await;
    });

    tokio::select! {
        _ = relay_task => {}
        _ = inbound_task => {}
        _ = writer_task => {}
    }
}

async fn relay_broadcast(
    mut broadcast_rx: broadcast::Receiver<StreamEvent>,
    outbound_tx: mpsc::Sender<String>,
    connection: Arc<Mutex<ConnectionState>>,
    replay_buffer: Arc<Mutex<ReplayBuffer>>,
) {
    while let Some(text) = next_relay_frame(&mut broadcast_rx, &connection, &replay_buffer).await {
        if outbound_tx.send(text).await.is_err() {
            break;
        }
    }
}

async fn next_relay_frame(
    broadcast_rx: &mut broadcast::Receiver<StreamEvent>,
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
) -> Option<String> {
    loop {
        let event = recv_broadcast_event(broadcast_rx).await?;
        if let Some(text) = prepare_push_frame(&event, connection, replay_buffer) {
            return Some(text);
        }
    }
}

/// Try to receive a single broadcast event, skipping lag errors.
/// Returns `None` only when the channel is closed.
async fn recv_broadcast_event(
    receiver: &mut broadcast::Receiver<StreamEvent>,
) -> Option<StreamEvent> {
    loop {
        return match receiver.recv().await {
            Ok(event) => Some(event),
            Err(broadcast::error::RecvError::Closed) => None,
            Err(broadcast::error::RecvError::Lagged(_)) => continue,
        };
    }
}

fn prepare_push_frame(
    event: &StreamEvent,
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
) -> Option<String> {
    let should_relay = {
        let state = connection.lock().expect("connection lock");
        state.should_relay(event)
    };
    if !should_relay {
        return None;
    }

    let seq = {
        let mut buffer = replay_buffer.lock().expect("replay buffer lock");
        let serialized = serde_json::to_string(event).unwrap_or_default();
        buffer.append(serialized)
    };

    let push = WsPushEvent {
        event: event.event.clone(),
        recorded_at: event.recorded_at.clone(),
        session_id: event.session_id.clone(),
        payload: event.payload.clone(),
        seq,
    };
    serde_json::to_string(&push).ok()
}

fn handle_message(
    text: &str,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> String {
    let request: WsRequest = match serde_json::from_str(text) {
        Ok(request) => request,
        Err(error) => {
            return serialize_error_response(
                None,
                "MALFORMED_MESSAGE",
                &format!("failed to parse message: {error}"),
            );
        }
    };

    let response = dispatch(&request, state, connection);
    serde_json::to_string(&response).unwrap_or_else(|error| {
        serialize_error_response(
            Some(&request.id),
            "SERIALIZE_ERROR",
            &format!("failed to serialize response: {error}"),
        )
    })
}

fn dispatch(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    match request.method.as_str() {
        "ping" => ok_response(&request.id, serde_json::json!({ "pong": true })),
        "health" | "diagnostics" | "daemon.stop" | "projects" | "sessions"
        | "session.detail" | "session.timeline" => {
            dispatch_read_query(request, state)
        }
        "session.subscribe" => handle_session_subscribe(request, connection),
        "session.unsubscribe" => handle_session_unsubscribe(request, connection),
        "stream.subscribe" => handle_stream_subscribe(request, connection),
        "stream.unsubscribe" => handle_stream_unsubscribe(request, connection),
        "task.create" => dispatch_mutation(request, state, |session_id, params| {
            let body: TaskCreateRequest = serde_json::from_value(params)?;
            service::create_task(&session_id, &body).map_err(Into::into)
        }),
        "task.assign" => {
            dispatch_mutation_with_task(request, state, |session_id, task_id, params| {
                let body: TaskAssignRequest = serde_json::from_value(params)?;
                service::assign_task(&session_id, &task_id, &body).map_err(Into::into)
            })
        }
        "task.update" => {
            dispatch_mutation_with_task(request, state, |session_id, task_id, params| {
                let body: TaskUpdateRequest = serde_json::from_value(params)?;
                service::update_task(&session_id, &task_id, &body).map_err(Into::into)
            })
        }
        "task.checkpoint" => {
            dispatch_mutation_with_task(request, state, |session_id, task_id, params| {
                let body: TaskCheckpointRequest = serde_json::from_value(params)?;
                service::checkpoint_task(&session_id, &task_id, &body).map_err(Into::into)
            })
        }
        "agent.change_role" => {
            dispatch_mutation_with_agent(request, state, |session_id, agent_id, params| {
                let body: RoleChangeRequest = serde_json::from_value(params)?;
                service::change_role(&session_id, &agent_id, &body).map_err(Into::into)
            })
        }
        "agent.remove" => {
            dispatch_mutation_with_agent(request, state, |session_id, agent_id, params| {
                let body: AgentRemoveRequest = serde_json::from_value(params)?;
                service::remove_agent(&session_id, &agent_id, &body).map_err(Into::into)
            })
        }
        "leader.transfer" => dispatch_mutation(request, state, |session_id, params| {
            let body: LeaderTransferRequest = serde_json::from_value(params)?;
            service::transfer_leader(&session_id, &body).map_err(Into::into)
        }),
        "session.end" => dispatch_mutation(request, state, |session_id, params| {
            let body: SessionEndRequest = serde_json::from_value(params)?;
            service::end_session(&session_id, &body).map_err(Into::into)
        }),
        "signal.send" => dispatch_mutation(request, state, |session_id, params| {
            let body: SignalSendRequest = serde_json::from_value(params)?;
            service::send_signal(&session_id, &body).map_err(Into::into)
        }),
        "session.observe" => dispatch_mutation(request, state, |session_id, params| {
            let body: ObserveSessionRequest = serde_json::from_value(params)?;
            service::observe_session(&session_id, Some(&body)).map_err(Into::into)
        }),
        unknown => error_response(
            &request.id,
            "UNKNOWN_METHOD",
            &format!("unknown method: {unknown}"),
        ),
    }
}

fn dispatch_read_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let db_guard = state.db.as_ref().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();

    match request.method.as_str() {
        "health" => dispatch_query(&request.id, || {
            service::health_response(&state.manifest, db_ref)
        }),
        "diagnostics" => dispatch_query(&request.id, || service::diagnostics_report(db_ref)),
        "daemon.stop" => dispatch_query(&request.id, service::request_shutdown),
        "projects" => dispatch_query(&request.id, || service::list_projects(db_ref)),
        "sessions" => dispatch_query(&request.id, || service::list_sessions(true, db_ref)),
        "session.detail" => match extract_session_id(&request.params) {
            Some(session_id) => dispatch_query(&request.id, || {
                service::session_detail(&session_id, db_ref)
            }),
            None => error_response(&request.id, "MISSING_PARAM", "missing session_id"),
        },
        "session.timeline" => match extract_session_id(&request.params) {
            Some(session_id) => dispatch_query(&request.id, || {
                service::session_timeline(&session_id, db_ref)
            }),
            None => error_response(&request.id, "MISSING_PARAM", "missing session_id"),
        },
        _ => error_response(&request.id, "UNKNOWN_METHOD", "unexpected read method"),
    }
}

fn handle_session_subscribe(
    request: &WsRequest,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    {
        let mut state = connection.lock().expect("connection lock");
        state.session_subscriptions.insert(session_id);
    }

    ok_response(&request.id, serde_json::json!({ "ok": true }))
}

fn handle_session_unsubscribe(
    request: &WsRequest,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    {
        let mut state = connection.lock().expect("connection lock");
        state.session_subscriptions.remove(&session_id);
    }

    ok_response(&request.id, serde_json::json!({ "ok": true }))
}

fn handle_stream_subscribe(
    request: &WsRequest,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    {
        let mut state = connection.lock().expect("connection lock");
        state.global_subscription = true;
    }
    ok_response(&request.id, serde_json::json!({ "ok": true }))
}

fn handle_stream_unsubscribe(
    request: &WsRequest,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    {
        let mut state = connection.lock().expect("connection lock");
        state.global_subscription = false;
    }
    ok_response(&request.id, serde_json::json!({ "ok": true }))
}

fn dispatch_query<T: serde::Serialize>(
    request_id: &str,
    query: impl FnOnce() -> Result<T, CliError>,
) -> WsResponse {
    match query() {
        Ok(value) => match serde_json::to_value(value) {
            Ok(json) => ok_response(request_id, json),
            Err(error) => error_response(
                request_id,
                "SERIALIZE_ERROR",
                &format!("failed to serialize result: {error}"),
            ),
        },
        Err(error) => error_response(request_id, error.code(), &error.message()),
    }
}

fn dispatch_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
    handler: impl FnOnce(String, Value) -> Result<super::protocol::SessionDetail, MutationError>,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    match handler(session_id.clone(), request.params.clone()) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id);
            match serde_json::to_value(detail) {
                Ok(json) => ok_response(&request.id, json),
                Err(error) => error_response(
                    &request.id,
                    "SERIALIZE_ERROR",
                    &format!("failed to serialize result: {error}"),
                ),
            }
        }
        Err(error) => error_response(&request.id, &error.code, &error.message),
    }
}

fn dispatch_mutation_with_task(
    request: &WsRequest,
    state: &DaemonHttpState,
    handler: impl FnOnce(String, String, Value) -> Result<super::protocol::SessionDetail, MutationError>,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let Some(task_id) = extract_string_param(&request.params, "task_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing task_id");
    };

    match handler(session_id.clone(), task_id, request.params.clone()) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id);
            match serde_json::to_value(detail) {
                Ok(json) => ok_response(&request.id, json),
                Err(error) => error_response(
                    &request.id,
                    "SERIALIZE_ERROR",
                    &format!("failed to serialize result: {error}"),
                ),
            }
        }
        Err(error) => error_response(&request.id, &error.code, &error.message),
    }
}

fn dispatch_mutation_with_agent(
    request: &WsRequest,
    state: &DaemonHttpState,
    handler: impl FnOnce(String, String, Value) -> Result<super::protocol::SessionDetail, MutationError>,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };

    match handler(session_id.clone(), agent_id, request.params.clone()) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id);
            match serde_json::to_value(detail) {
                Ok(json) => ok_response(&request.id, json),
                Err(error) => error_response(
                    &request.id,
                    "SERIALIZE_ERROR",
                    &format!("failed to serialize result: {error}"),
                ),
            }
        }
        Err(error) => error_response(&request.id, &error.code, &error.message),
    }
}

struct MutationError {
    code: String,
    message: String,
}

impl From<CliError> for MutationError {
    fn from(error: CliError) -> Self {
        Self {
            code: error.code().to_string(),
            message: error.message(),
        }
    }
}

impl From<serde_json::Error> for MutationError {
    fn from(error: serde_json::Error) -> Self {
        Self {
            code: "INVALID_PARAMS".into(),
            message: format!("failed to parse request params: {error}"),
        }
    }
}

fn extract_session_id(params: &Value) -> Option<String> {
    extract_string_param(params, "session_id")
}

fn extract_string_param(params: &Value, key: &str) -> Option<String> {
    params.get(key).and_then(Value::as_str).map(String::from)
}

fn ok_response(request_id: &str, result: Value) -> WsResponse {
    WsResponse {
        id: request_id.into(),
        result: Some(result),
        error: None,
    }
}

fn error_response(request_id: &str, code: &str, message: &str) -> WsResponse {
    WsResponse {
        id: request_id.into(),
        result: None,
        error: Some(WsErrorPayload {
            code: code.into(),
            message: message.into(),
            details: vec![],
        }),
    }
}

fn serialize_error_response(request_id: Option<&str>, code: &str, message: &str) -> String {
    let response = WsResponse {
        id: request_id.unwrap_or("").into(),
        result: None,
        error: Some(WsErrorPayload {
            code: code.into(),
            message: message.into(),
            details: vec![],
        }),
    };
    serde_json::to_string(&response).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_buffer_append_and_replay() {
        let mut buffer = ReplayBuffer::new(4);
        assert_eq!(buffer.current_seq(), 0);

        let seq1 = buffer.append("event-1".into());
        let seq2 = buffer.append("event-2".into());
        let seq3 = buffer.append("event-3".into());
        assert_eq!(seq1, 1);
        assert_eq!(seq2, 2);
        assert_eq!(seq3, 3);
        assert_eq!(buffer.current_seq(), 3);

        let replayed = buffer.replay_since(1).expect("replay should succeed");
        assert_eq!(replayed.len(), 2);
        assert_eq!(replayed[0], (2, "event-2".into()));
        assert_eq!(replayed[1], (3, "event-3".into()));

        let replayed = buffer.replay_since(0).expect("replay should succeed");
        assert_eq!(replayed.len(), 3);
    }

    #[test]
    fn replay_buffer_evicts_old_entries() {
        let mut buffer = ReplayBuffer::new(3);
        buffer.append("event-1".into());
        buffer.append("event-2".into());
        buffer.append("event-3".into());
        buffer.append("event-4".into());

        assert_eq!(buffer.entries.len(), 3);
        assert_eq!(buffer.entries.front().unwrap().0, 2);

        let replay_from_0 = buffer.replay_since(0);
        assert!(replay_from_0.is_none(), "gap too large, should return None");

        let replayed = buffer.replay_since(1).expect("replay should succeed");
        assert_eq!(replayed.len(), 3);
    }

    #[test]
    fn replay_buffer_empty() {
        let buffer = ReplayBuffer::new(10);
        assert_eq!(buffer.current_seq(), 0);
        assert!(buffer.replay_since(0).is_none());
    }

    #[test]
    fn connection_state_relay_filtering() {
        let mut state = ConnectionState::new();
        let global_event = StreamEvent {
            event: "sessions_updated".into(),
            recorded_at: "2026-03-29T12:00:00Z".into(),
            session_id: None,
            payload: serde_json::json!({}),
        };
        let session_event = StreamEvent {
            event: "session_updated".into(),
            recorded_at: "2026-03-29T12:00:00Z".into(),
            session_id: Some("sess-1".into()),
            payload: serde_json::json!({}),
        };

        assert!(!state.should_relay(&global_event));
        assert!(!state.should_relay(&session_event));

        state.session_subscriptions.insert("sess-1".into());
        assert!(!state.should_relay(&global_event));
        assert!(state.should_relay(&session_event));

        state.global_subscription = true;
        assert!(state.should_relay(&global_event));
        assert!(state.should_relay(&session_event));
    }

    #[test]
    fn ws_request_deserialization() {
        let json = r#"{"id":"abc-123","method":"health","params":{}}"#;
        let request: WsRequest = serde_json::from_str(json).expect("deserialize");
        assert_eq!(request.id, "abc-123");
        assert_eq!(request.method, "health");
    }

    #[test]
    fn ws_response_serialization() {
        let response = ok_response("req-1", serde_json::json!({ "status": "ok" }));
        let json = serde_json::to_string(&response).expect("serialize");
        assert!(json.contains(r#""id":"req-1""#));
        assert!(json.contains(r#""status":"ok""#));
        assert!(!json.contains("error"));
    }

    #[test]
    fn ws_error_response_serialization() {
        let response = error_response("req-2", "NOT_FOUND", "session not found");
        let json = serde_json::to_string(&response).expect("serialize");
        assert!(json.contains(r#""code":"NOT_FOUND""#));
        assert!(!json.contains("result"));
    }
}
