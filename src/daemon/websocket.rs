use std::collections::{HashSet, VecDeque};
use std::mem;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::response::Response;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;
use tokio::time::{Instant, interval as tokio_interval};
use tracing::{debug, info};

use crate::errors::CliError;

use super::http::DaemonHttpState;
use super::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, ObserveSessionRequest, RoleChangeRequest,
    SessionEndRequest, SetLogLevelRequest, SignalCancelRequest, SignalSendRequest, StreamEvent,
    TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest,
    TaskQueuePolicyRequest, TaskUpdateRequest, WsChunkFrame, WsErrorPayload, WsPushEvent,
    WsRequest, WsResponse, bind_control_plane_actor_value,
};
use super::read_cache::run_preferred_db_read;
use super::service;

const MAX_INLINE_WS_TEXT_BYTES: usize = 256 * 1024;
const MAX_SEMANTIC_WS_ARRAY_BATCH_BYTES: usize = 128 * 1024;
const MAX_SEMANTIC_WS_ARRAY_BATCH_ITEMS: usize = 64;
const WS_CHUNK_DATA_BYTES: usize = 128 * 1024;

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

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn handle_connection(socket: WebSocket, state: DaemonHttpState) {
    tracing::info!("websocket connection opened");
    let (mut sender, mut receiver) = socket.split();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));

    // Two outbound channels: priority for pings/dispatch responses (latency-
    // sensitive), bulk for broadcast relay events. The writer task drains the
    // priority channel first so pong frames are never blocked behind large
    // broadcast payloads.
    let (priority_tx, mut priority_rx) = mpsc::channel::<Message>(64);
    let (bulk_tx, mut bulk_rx) = mpsc::channel::<Message>(256);
    let broadcast_rx = state.sender.subscribe();

    let connection_relay = Arc::clone(&connection);
    let replay_buffer = Arc::clone(&state.replay_buffer);
    let relay_state = state.clone();
    let relay_task = tokio::spawn(relay_broadcast(
        broadcast_rx,
        bulk_tx,
        connection_relay,
        replay_buffer,
        relay_state,
    ));

    let priority_tx_dispatch = priority_tx.clone();
    let connection_dispatch = Arc::clone(&connection);
    let inbound_task = tokio::spawn(async move {
        let mut last_client_message = Instant::now();
        let mut idle_check = tokio_interval(Duration::from_secs(15));

        loop {
            tokio::select! {
                message = receiver.next() => {
                    match message {
                        Some(Ok(message)) => {
                            if incoming_message_counts_as_activity(&message) {
                                last_client_message = Instant::now();
                            }
                            match handle_incoming_message(
                                message,
                                &state,
                                &connection_dispatch,
                            )
                            .await
                            {
                                IncomingMessageAction::ContinueLoop => {}
                                IncomingMessageAction::CloseConnection => break,
                                IncomingMessageAction::RespondBatch(frames) => {
                                    for frame in frames {
                                        if priority_tx_dispatch.send(frame).await.is_err() {
                                            return;
                                        }
                                    }
                                }
                            }
                        }
                        None => break,
                        Some(Err(error)) => {
                            debug!(%error, "websocket receive error");
                            break;
                        }
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

    // Writer task: drain priority channel first (pong, dispatch responses),
    // then bulk channel (broadcast events). Uses biased select so priority
    // frames are always sent before broadcast frames when both are ready.
    let writer_task = tokio::spawn(async move {
        loop {
            let message = tokio::select! {
                biased;
                msg = priority_rx.recv() => msg,
                msg = bulk_rx.recv() => msg,
            };
            let Some(message) = message else {
                break;
            };
            if sender.send(message).await.is_err() {
                break;
            }
        }
        let _ = sender.close().await;
    });

    await_connection_tasks(relay_task, inbound_task, writer_task).await;
    tracing::info!("websocket connection closed");
}

async fn await_connection_tasks(
    mut relay_task: JoinHandle<()>,
    mut inbound_task: JoinHandle<()>,
    mut writer_task: JoinHandle<()>,
) {
    let completed =
        select_connection_task(&mut relay_task, &mut inbound_task, &mut writer_task).await;
    abort_connection_siblings(completed, &relay_task, &inbound_task, &writer_task);
    await_connection_siblings(completed, relay_task, inbound_task, writer_task).await;
}

#[derive(Clone, Copy)]
enum CompletedConnectionTask {
    Relay,
    Inbound,
    Writer,
}

async fn select_connection_task(
    relay_task: &mut JoinHandle<()>,
    inbound_task: &mut JoinHandle<()>,
    writer_task: &mut JoinHandle<()>,
) -> CompletedConnectionTask {
    tokio::select! {
        _ = relay_task => CompletedConnectionTask::Relay,
        _ = inbound_task => CompletedConnectionTask::Inbound,
        _ = writer_task => CompletedConnectionTask::Writer,
    }
}

fn abort_connection_siblings(
    completed: CompletedConnectionTask,
    relay_task: &JoinHandle<()>,
    inbound_task: &JoinHandle<()>,
    writer_task: &JoinHandle<()>,
) {
    match completed {
        CompletedConnectionTask::Relay => {
            inbound_task.abort();
            writer_task.abort();
        }
        CompletedConnectionTask::Inbound => {
            relay_task.abort();
            writer_task.abort();
        }
        CompletedConnectionTask::Writer => {
            relay_task.abort();
            inbound_task.abort();
        }
    }
}

async fn await_connection_siblings(
    completed: CompletedConnectionTask,
    relay_task: JoinHandle<()>,
    inbound_task: JoinHandle<()>,
    writer_task: JoinHandle<()>,
) {
    let (first, second) = match completed {
        CompletedConnectionTask::Relay => (inbound_task, writer_task),
        CompletedConnectionTask::Inbound => (relay_task, writer_task),
        CompletedConnectionTask::Writer => (relay_task, inbound_task),
    };
    let _ = first.await;
    let _ = second.await;
}

enum IncomingMessageAction {
    ContinueLoop,
    CloseConnection,
    RespondBatch(Vec<Message>),
}

fn incoming_message_counts_as_activity(message: &Message) -> bool {
    matches!(
        message,
        Message::Text(_) | Message::Binary(_) | Message::Ping(_) | Message::Pong(_)
    )
}

async fn handle_incoming_message(
    message: Message,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> IncomingMessageAction {
    match message {
        Message::Text(text) => {
            IncomingMessageAction::RespondBatch(handle_message(&text, state, connection).await)
        }
        Message::Ping(payload) => IncomingMessageAction::RespondBatch(vec![Message::Pong(payload)]),
        Message::Close(_) => IncomingMessageAction::CloseConnection,
        Message::Binary(_) | Message::Pong(_) => IncomingMessageAction::ContinueLoop,
    }
}

async fn relay_broadcast(
    mut broadcast_rx: broadcast::Receiver<StreamEvent>,
    outbound_tx: mpsc::Sender<Message>,
    connection: Arc<Mutex<ConnectionState>>,
    replay_buffer: Arc<Mutex<ReplayBuffer>>,
    state: DaemonHttpState,
) {
    while let Some(frames) =
        next_relay_frames(&mut broadcast_rx, &connection, &replay_buffer, &state).await
    {
        for frame in frames {
            if outbound_tx.send(frame).await.is_err() {
                return;
            }
        }
    }
}

async fn next_relay_frames(
    broadcast_rx: &mut broadcast::Receiver<StreamEvent>,
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
    state: &DaemonHttpState,
) -> Option<Vec<Message>> {
    loop {
        match recv_broadcast_event(broadcast_rx, connection, state).await? {
            RelayBatch::Live(event) => {
                if let Some(frames) = prepare_push_frames(&event, connection, replay_buffer) {
                    return Some(frames);
                }
            }
            RelayBatch::Recovery(events) => {
                let frames = prepare_recovery_frames(&events, connection, replay_buffer);
                if !frames.is_empty() {
                    return Some(frames);
                }
            }
        }
    }
}

enum RelayBatch {
    Live(StreamEvent),
    Recovery(Vec<StreamEvent>),
}

/// Try to receive a single relay batch.
/// Returns `None` only when the channel is closed.
async fn recv_broadcast_event(
    receiver: &mut broadcast::Receiver<StreamEvent>,
    connection: &Arc<Mutex<ConnectionState>>,
    state: &DaemonHttpState,
) -> Option<RelayBatch> {
    loop {
        let batch = match receiver.recv().await {
            Ok(event) => Some(RelayBatch::Live(event)),
            Err(broadcast::error::RecvError::Closed) => None,
            Err(broadcast::error::RecvError::Lagged(skipped)) => {
                lagged_relay_batch(skipped, connection, state).await
            }
        };
        if let Some(batch) = batch {
            return Some(batch);
        }
    }
}

async fn lagged_relay_batch(
    skipped: u64,
    connection: &Arc<Mutex<ConnectionState>>,
    state: &DaemonHttpState,
) -> Option<RelayBatch> {
    let events = recovery_events_for_connection(connection, state).await;
    warn_lagged_recovery(skipped, events.len());
    (!events.is_empty()).then_some(RelayBatch::Recovery(events))
}

#[derive(Clone, Debug, Default)]
struct RelayRecoveryPlan {
    include_sessions_updated: bool,
    session_ids: Vec<String>,
}

impl RelayRecoveryPlan {
    fn is_empty(&self) -> bool {
        !self.include_sessions_updated && self.session_ids.is_empty()
    }
}

fn recovery_plan_for_connection(connection: &Arc<Mutex<ConnectionState>>) -> RelayRecoveryPlan {
    let state = connection.lock().expect("connection lock");
    let mut session_ids: Vec<_> = state.session_subscriptions.iter().cloned().collect();
    session_ids.sort();
    RelayRecoveryPlan {
        include_sessions_updated: state.global_subscription,
        session_ids,
    }
}

async fn recovery_events_for_connection(
    connection: &Arc<Mutex<ConnectionState>>,
    state: &DaemonHttpState,
) -> Vec<StreamEvent> {
    let plan = recovery_plan_for_connection(connection);
    if plan.is_empty() {
        return Vec::new();
    }

    run_preferred_db_read(
        &state.db,
        "websocket recovery snapshot",
        {
            let plan = plan.clone();
            move |db| Ok(build_recovery_events(&plan, Some(db)))
        },
        move || Ok(build_recovery_events(&plan, None)),
    )
    .await
    .unwrap_or_else(|error| recovery_events_on_error(&error))
}

fn recovery_events_on_error(error: &CliError) -> Vec<StreamEvent> {
    warn_recovery_snapshot_failure(error);
    Vec::new()
}

fn build_recovery_events(
    plan: &RelayRecoveryPlan,
    db: Option<&super::db::DaemonDb>,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    if plan.include_sessions_updated {
        append_recovery_event(
            &mut events,
            service::sessions_updated_event(db),
            "sessions_updated",
            None,
        );
    }
    for session_id in &plan.session_ids {
        append_recovery_event(
            &mut events,
            service::session_updated_core_event(session_id, db),
            "session_updated",
            Some(session_id),
        );
    }
    events
}

fn append_recovery_event(
    events: &mut Vec<StreamEvent>,
    event: Result<StreamEvent, CliError>,
    event_name: &str,
    session_id: Option<&str>,
) {
    match event {
        Ok(event) => events.push(event),
        Err(error) => warn_recovery_event_failure(&error, event_name, session_id),
    }
}

fn prepare_recovery_frames(
    events: &[StreamEvent],
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
) -> Vec<Message> {
    let mut frames = Vec::new();
    for event in events {
        if let Some(event_frames) = prepare_push_frames(event, connection, replay_buffer) {
            frames.extend(event_frames);
        }
    }
    frames
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_lagged_recovery(skipped: u64, recovery_events: usize) {
    tracing::warn!(
        skipped,
        recovery_events,
        "websocket relay lagged; sending recovery snapshot"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_recovery_snapshot_failure(error: &CliError) {
    tracing::warn!(%error, "failed to build websocket recovery snapshot");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_recovery_event_failure(error: &CliError, event_name: &str, session_id: Option<&str>) {
    tracing::warn!(
        %error,
        event = event_name,
        session_id = session_id.unwrap_or("-"),
        "failed to build websocket recovery event"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn prepare_push_frames(
    event: &StreamEvent,
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
) -> Option<Vec<Message>> {
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
    let frames = serialize_push_frames(&push).ok();
    if let Some(ref frames) = frames {
        tracing::info!(
            event = %event.event,
            session_id = event.session_id.as_deref().unwrap_or("-"),
            seq,
            frame_count = frames.len(),
            "ws push"
        );
    }
    frames
}

async fn handle_message(
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
async fn dispatch(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let start = Instant::now();
    let response = dispatch_inner(request, state, connection).await;
    let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    let is_error = response.error.is_some();
    tracing::info!(
        method = %request.method,
        request_id = %request.id,
        duration_ms,
        is_error,
        "ws dispatch"
    );
    response
}

async fn dispatch_inner(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    match request.method.as_str() {
        "ping" => ok_response(&request.id, serde_json::json!({ "pong": true })),
        "health" | "diagnostics" | "daemon.stop" | "daemon.log_level" | "projects" | "sessions"
        | "session.detail" | "session.timeline" => dispatch_read_query(request, state).await,
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

async fn dispatch_read_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    match request.method.as_str() {
        "health" => dispatch_health_query(&request.id, state),
        "diagnostics" => dispatch_diagnostics_query(&request.id, state),
        "daemon.stop" => dispatch_query(&request.id, service::request_shutdown),
        "daemon.log_level" => dispatch_query(&request.id, service::get_log_level),
        "projects" => dispatch_projects_query(&request.id, state).await,
        "sessions" => dispatch_sessions_query(&request.id, state).await,
        "session.detail" => dispatch_session_detail_query(request, state).await,
        "session.timeline" => dispatch_session_timeline_query(request, state).await,
        _ => error_response(&request.id, "UNKNOWN_METHOD", "unexpected read method"),
    }
}

async fn dispatch_projects_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    dispatch_query_result(
        request_id,
        run_preferred_db_read(
            &state.db,
            "projects",
            |db| service::list_projects(Some(db)),
            || service::list_projects(None),
        )
        .await,
    )
}

async fn dispatch_sessions_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    dispatch_query_result(
        request_id,
        run_preferred_db_read(
            &state.db,
            "sessions",
            |db| service::list_sessions(true, Some(db)),
            || service::list_sessions(true, None),
        )
        .await,
    )
}

async fn dispatch_session_detail_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    let scope = extract_string_param(&request.params, "scope");
    if scope.as_deref() == Some("core") {
        return dispatch_session_detail_core_query(&request.id, state, session_id).await;
    }

    dispatch_query_result(
        &request.id,
        run_preferred_db_read(
            &state.db,
            "session detail",
            {
                let session_id = session_id.clone();
                move |db| service::session_detail(&session_id, Some(db))
            },
            || service::session_detail(&session_id, None),
        )
        .await,
    )
}

async fn dispatch_session_detail_core_query(
    request_id: &str,
    state: &DaemonHttpState,
    session_id: String,
) -> WsResponse {
    let response = dispatch_query_result(
        request_id,
        run_preferred_db_read(
            &state.db,
            "session detail core",
            {
                let session_id = session_id.clone();
                move |db| service::session_detail_core(&session_id, Some(db))
            },
            || service::session_detail_core(&session_id, None),
        )
        .await,
    );
    schedule_extensions_push(&state.sender, &state.db, &session_id);
    response
}

async fn dispatch_session_timeline_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    dispatch_query_result(
        &request.id,
        run_preferred_db_read(
            &state.db,
            "session timeline",
            {
                let session_id = session_id.clone();
                move |db| service::session_timeline(&session_id, Some(db))
            },
            || service::session_timeline(&session_id, None),
        )
        .await,
    )
}

fn dispatch_health_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    let db_guard = try_db_guard(state);
    dispatch_query(request_id, || {
        service::health_response(&state.manifest, db_guard.as_deref())
    })
}

fn dispatch_diagnostics_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    let db_guard = try_db_guard(state);
    dispatch_query(request_id, || {
        service::diagnostics_report(db_guard.as_deref())
    })
}

fn try_db_guard(state: &DaemonHttpState) -> Option<MutexGuard<'_, super::db::DaemonDb>> {
    state.db.get().and_then(|db| db.try_lock().ok())
}

/// Schedule an asynchronous push of session extensions through the broadcast channel.
///
/// The extensions (signals, observer, agent activity) are computed on a blocking
/// thread pool task, acquiring the DB lock independently from the request path.
fn schedule_extensions_push(
    sender: &broadcast::Sender<super::protocol::StreamEvent>,
    db: &Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
    session_id: &str,
) {
    use tokio::task::{spawn, spawn_blocking};

    let sender = sender.clone();
    let db = db.clone();
    let session_id = session_id.to_string();
    spawn(async move {
        let result = spawn_blocking(move || {
            let db_guard = db.get().map(|db| db.lock().expect("db lock"));
            let db_ref = db_guard.as_deref();
            service::session_extensions_event(&session_id, db_ref)
        })
        .await;
        if let Ok(Ok(event)) = result {
            let _ = sender.send(event);
        }
    });
}

async fn handle_session_subscribe(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    {
        let mut state = connection.lock().expect("connection lock");
        state.session_subscriptions.insert(session_id.clone());
    }

    let sender = state.sender.clone();
    let _ = run_preferred_db_read(
        &state.db,
        "session subscribe snapshot",
        {
            let session_id = session_id.clone();
            let sender = sender.clone();
            move |db| {
                service::broadcast_session_snapshot(&sender, &session_id, Some(db));
                Ok(())
            }
        },
        || {
            service::broadcast_session_snapshot(&sender, &session_id, None);
            Ok(())
        },
    )
    .await;

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
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    {
        let mut state = connection.lock().expect("connection lock");
        state.global_subscription = true;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    service::broadcast_sessions_updated(&state.sender, db_ref);
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
    dispatch_query_result(request_id, query())
}

fn dispatch_query_result<T: serde::Serialize>(
    request_id: &str,
    result: Result<T, CliError>,
) -> WsResponse {
    match result {
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
    handler: impl FnOnce(
        String,
        Value,
        Option<&super::db::DaemonDb>,
    ) -> Result<super::protocol::SessionDetail, MutationError>,
) -> WsResponse {
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match handler(session_id.clone(), params, db_ref) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
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
    handler: impl FnOnce(
        String,
        String,
        Value,
        Option<&super::db::DaemonDb>,
    ) -> Result<super::protocol::SessionDetail, MutationError>,
) -> WsResponse {
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let Some(task_id) = extract_string_param(&request.params, "task_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing task_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match handler(session_id.clone(), task_id, params, db_ref) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
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
    handler: impl FnOnce(
        String,
        String,
        Value,
        Option<&super::db::DaemonDb>,
    ) -> Result<super::protocol::SessionDetail, MutationError>,
) -> WsResponse {
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match handler(session_id.clone(), agent_id, params, db_ref) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
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
        batch_index: None,
        batch_count: None,
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
        batch_index: None,
        batch_count: None,
    }
}

fn serialize_response_frames(response: &WsResponse) -> Result<Vec<Message>, serde_json::Error> {
    if let Some(frames) = serialize_semantic_array_response_frames(response)? {
        return Ok(frames);
    }
    serialize_ws_frames(response, &format!("response:{}", response.id))
}

fn serialize_semantic_array_response_frames(
    response: &WsResponse,
) -> Result<Option<Vec<Message>>, serde_json::Error> {
    let Some(Value::Array(items)) = response.result.as_ref() else {
        return Ok(None);
    };
    if response.error.is_some() || items.is_empty() {
        return Ok(None);
    }

    let batches = build_semantic_array_batches(items)?;
    if batches.len() <= 1 {
        return Ok(None);
    }

    let batch_count = batches.len();
    let mut frames = Vec::with_capacity(batch_count);
    for (batch_index, batch_items) in batches.into_iter().enumerate() {
        let batch_response = WsResponse {
            id: response.id.clone(),
            result: Some(Value::Array(batch_items)),
            error: None,
            batch_index: Some(batch_index),
            batch_count: Some(batch_count),
        };
        frames.extend(serialize_ws_frames(
            &batch_response,
            &format!("response:{}:batch:{batch_index}", response.id),
        )?);
    }
    Ok(Some(frames))
}

fn build_semantic_array_batches(items: &[Value]) -> Result<Vec<Vec<Value>>, serde_json::Error> {
    let mut batches = Vec::new();
    let mut current = Vec::new();
    let mut current_bytes = 0usize;

    for item in items {
        let item_bytes = serde_json::to_vec(item)?.len();
        let reached_item_limit = current.len() >= MAX_SEMANTIC_WS_ARRAY_BATCH_ITEMS;
        let reached_byte_limit =
            !current.is_empty() && current_bytes + item_bytes > MAX_SEMANTIC_WS_ARRAY_BATCH_BYTES;
        if reached_item_limit || reached_byte_limit {
            batches.push(mem::take(&mut current));
            current_bytes = 0;
        }

        current.push(item.clone());
        current_bytes += item_bytes;
    }

    if !current.is_empty() {
        batches.push(current);
    }

    Ok(batches)
}

fn serialize_push_frames(push: &WsPushEvent) -> Result<Vec<Message>, serde_json::Error> {
    serialize_ws_frames(push, &format!("push:{}", push.seq))
}

fn serialize_ws_frames(
    frame: &impl serde::Serialize,
    chunk_id: &str,
) -> Result<Vec<Message>, serde_json::Error> {
    let serialized = serde_json::to_string(frame)?;
    Ok(chunk_serialized_text(serialized, chunk_id))
}

fn chunk_serialized_text(serialized: String, chunk_id: &str) -> Vec<Message> {
    if serialized.len() <= MAX_INLINE_WS_TEXT_BYTES {
        return vec![Message::text(serialized)];
    }

    let bytes = serialized.into_bytes();
    let chunk_count = bytes.len().div_ceil(WS_CHUNK_DATA_BYTES);
    bytes
        .chunks(WS_CHUNK_DATA_BYTES)
        .enumerate()
        .map(|(chunk_index, chunk)| {
            let frame = WsChunkFrame {
                chunk_id: chunk_id.to_string(),
                chunk_index,
                chunk_count,
                chunk_base64: BASE64_STANDARD.encode(chunk),
            };
            Message::text(serde_json::to_string(&frame).expect("serialize ws chunk frame"))
        })
        .collect()
}

fn serialize_error_response_frames(
    request_id: Option<&str>,
    code: &str,
    message: &str,
) -> Vec<Message> {
    let response = WsResponse {
        id: request_id.unwrap_or("").into(),
        result: None,
        error: Some(WsErrorPayload {
            code: code.into(),
            message: message.into(),
            details: vec![],
        }),
        batch_index: None,
        batch_count: None,
    };
    serialize_response_frames(&response).unwrap_or_else(|_| vec![Message::text("{}")])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::agent_tui::AgentTuiManagerHandle;
    use crate::daemon::codex_controller::CodexControllerHandle;
    use crate::daemon::state::{DaemonManifest, HostBridgeManifest};
    use crate::session::types::CONTROL_PLANE_ACTOR_ID;
    use serde_json::json;
    use std::sync::{Arc, Mutex, OnceLock};
    use tokio::sync::broadcast;

    fn test_ws_state() -> DaemonHttpState {
        let (sender, _) = broadcast::channel(8);
        let db_slot = Arc::new(OnceLock::new());
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
            replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
            db: db_slot.clone(),
            codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
            agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
        }
    }

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
    fn dispatch_mutation_rebinds_client_actor() {
        let state = test_ws_state();
        let request = WsRequest {
            id: "req-1".into(),
            method: "session.end".into(),
            params: json!({
                "session_id": "sess-1",
                "actor": "spoofed-leader",
            }),
        };

        let response = dispatch_mutation(&request, &state, |session_id, params, _db| {
            assert_eq!(session_id, "sess-1");
            assert_eq!(params["actor"], CONTROL_PLANE_ACTOR_ID);
            Err(MutationError {
                code: "EXPECTED".into(),
                message: "stop here".into(),
            })
        });

        assert_eq!(
            response.error.as_ref().map(|error| error.code.as_str()),
            Some("EXPECTED")
        );
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

    #[tokio::test]
    async fn next_relay_frames_emits_sessions_updated_after_global_lag() {
        let state = test_http_state_with_db();
        let connection = Arc::new(Mutex::new(ConnectionState::new()));
        connection
            .lock()
            .expect("connection lock")
            .global_subscription = true;

        let (sender, _) = broadcast::channel::<StreamEvent>(1);
        let mut receiver = sender.subscribe();
        sender
            .send(StreamEvent {
                event: "session_updated".into(),
                recorded_at: "2026-04-13T19:00:00Z".into(),
                session_id: Some("sess-test-1".into()),
                payload: json!({}),
            })
            .expect("send first event");
        sender
            .send(StreamEvent {
                event: "session_updated".into(),
                recorded_at: "2026-04-13T19:00:01Z".into(),
                session_id: Some("sess-test-1".into()),
                payload: json!({}),
            })
            .expect("send second event");

        let frames =
            next_relay_frames(&mut receiver, &connection, &state.replay_buffer, &state).await;
        let Message::Text(text) = &frames.expect("recovery frames")[0] else {
            panic!("expected inline websocket push frame");
        };
        let push: WsPushEvent =
            serde_json::from_str(text).expect("deserialize websocket push frame");

        assert_eq!(push.event, "sessions_updated");
        assert!(push.session_id.is_none());
    }

    #[tokio::test]
    async fn next_relay_frames_emits_session_snapshot_after_session_lag() {
        let state = test_http_state_with_db();
        {
            use std::collections::BTreeMap;

            use crate::agents::runtime::RuntimeCapabilities;
            use crate::daemon::index::DiscoveredProject;
            use crate::session::types::{
                AgentRegistration, AgentStatus, SessionMetrics, SessionRole, SessionState,
                SessionStatus,
            };

            let db = state.db.get().expect("db slot").clone();
            let db = db.lock().expect("db lock");
            let project = DiscoveredProject {
                project_id: "project-abc123".into(),
                name: "harness".into(),
                project_dir: Some("/tmp/harness".into()),
                repository_root: Some("/tmp/harness".into()),
                checkout_id: "checkout-abc123".into(),
                checkout_name: "Repository".into(),
                context_root: "/tmp/data/projects/project-abc123".into(),
                is_worktree: false,
                worktree_name: None,
            };
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
            let session_state = SessionState {
                schema_version: 3,
                state_version: 1,
                session_id: "sess-test-1".into(),
                title: "sess-test-1".into(),
                context: "websocket lag recovery fixture".into(),
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
            };
            db.sync_project(&project).expect("sync project");
            db.save_session_state(&project.project_id, &session_state)
                .expect("save session state");
        }
        let connection = Arc::new(Mutex::new(ConnectionState::new()));
        connection
            .lock()
            .expect("connection lock")
            .session_subscriptions
            .insert("sess-test-1".into());

        let (sender, _) = broadcast::channel::<StreamEvent>(1);
        let mut receiver = sender.subscribe();
        sender
            .send(StreamEvent {
                event: "sessions_updated".into(),
                recorded_at: "2026-04-13T19:00:00Z".into(),
                session_id: None,
                payload: json!({}),
            })
            .expect("send first event");
        sender
            .send(StreamEvent {
                event: "sessions_updated".into(),
                recorded_at: "2026-04-13T19:00:01Z".into(),
                session_id: None,
                payload: json!({}),
            })
            .expect("send second event");

        let frames =
            next_relay_frames(&mut receiver, &connection, &state.replay_buffer, &state).await;
        let Message::Text(text) = &frames.expect("recovery frames")[0] else {
            panic!("expected inline websocket push frame");
        };
        let push: WsPushEvent =
            serde_json::from_str(text).expect("deserialize websocket push frame");

        assert_eq!(push.event, "session_updated");
        assert_eq!(push.session_id.as_deref(), Some("sess-test-1"));
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

    #[test]
    fn oversized_ws_responses_are_chunked() {
        let response = ok_response(
            "req-large",
            json!({
                "timeline": "x".repeat(300_000),
            }),
        );

        let frames = serialize_response_frames(&response).expect("serialize response frames");

        assert!(
            frames.len() > 1,
            "large response should be split into chunks"
        );
    }

    #[test]
    fn oversized_ws_push_events_are_chunked() {
        let push = WsPushEvent {
            event: "session_extensions".into(),
            recorded_at: "2026-04-13T00:00:00Z".into(),
            session_id: Some("sess-large".into()),
            payload: json!({
                "agent_activity": "x".repeat(300_000),
            }),
            seq: 7,
        };

        let frames = serialize_push_frames(&push).expect("serialize push frames");

        assert!(
            frames.len() > 1,
            "large push event should be split into chunks"
        );
    }

    #[test]
    fn large_array_responses_use_semantic_batches_before_binary_chunking() {
        let items: Vec<Value> = (0..320)
            .map(|index| {
                json!({
                    "entry_id": format!("entry-{index}"),
                    "summary": "x".repeat(2_048),
                })
            })
            .collect();
        let response = WsResponse {
            id: "req-array".into(),
            result: Some(Value::Array(items)),
            error: None,
            batch_index: None,
            batch_count: None,
        };

        let frames = serialize_response_frames(&response).expect("serialize response frames");

        assert!(
            frames.len() > 1,
            "large array response should be split into semantic batches"
        );
        let mut seen_indices = Vec::new();
        let mut expected_batch_count = None;
        for frame in frames {
            let Message::Text(text) = frame else {
                panic!("semantic batches should stay as JSON text frames");
            };
            let response: WsResponse =
                serde_json::from_str(&text).expect("deserialize semantic response batch");
            let batch_index = response.batch_index.expect("batch index");
            let batch_count = response.batch_count.expect("batch count");
            let result = response.result.expect("batch result");
            assert!(
                matches!(result, Value::Array(_)),
                "each semantic batch should carry displayable array entries"
            );
            if let Some(expected) = expected_batch_count {
                assert_eq!(batch_count, expected);
            } else {
                expected_batch_count = Some(batch_count);
            }
            seen_indices.push(batch_index);
        }
        seen_indices.sort_unstable();
        assert_eq!(
            seen_indices,
            (0..expected_batch_count.expect("semantic batch count")).collect::<Vec<_>>()
        );
    }

    #[test]
    fn incoming_ping_frames_count_as_activity() {
        assert!(incoming_message_counts_as_activity(&Message::Ping(
            vec![1, 2, 3].into(),
        )));
        assert!(incoming_message_counts_as_activity(&Message::Pong(
            vec![1, 2, 3].into(),
        )));
        assert!(!incoming_message_counts_as_activity(&Message::Close(None)));
    }

    #[tokio::test]
    async fn await_connection_tasks_releases_relay_receiver_when_a_sibling_exits() {
        let (sender, _) = broadcast::channel::<StreamEvent>(8);
        let relay_task = tokio::spawn({
            let mut receiver = sender.subscribe();
            async move {
                let _ = receiver.recv().await;
            }
        });
        let inbound_task = tokio::spawn(async {});
        let writer_task = tokio::spawn(async {
            tokio::time::sleep(Duration::from_secs(60)).await;
        });

        await_connection_tasks(relay_task, inbound_task, writer_task).await;
        tokio::task::yield_now().await;

        assert_eq!(
            sender.receiver_count(),
            0,
            "relay task should release its broadcast receiver when the connection closes"
        );
    }

    #[tokio::test]
    async fn incoming_ping_frames_reply_with_matching_pong() {
        let state = test_http_state();
        let connection = Arc::new(Mutex::new(ConnectionState::new()));

        let action =
            handle_incoming_message(Message::Ping(vec![4, 5, 6].into()), &state, &connection).await;

        match action {
            IncomingMessageAction::RespondBatch(frames) => {
                assert_eq!(frames.len(), 1);
                match &frames[0] {
                    Message::Pong(payload) => {
                        assert_eq!(payload.as_ref(), [4, 5, 6]);
                    }
                    _ => panic!("expected pong response"),
                }
            }
            _ => panic!("expected pong response batch"),
        }
    }

    #[tokio::test]
    async fn dispatch_read_query_health_succeeds_when_db_lock_is_held() {
        let state = test_http_state_with_db();
        let db = state.db.get().expect("db slot").clone();
        let _db_guard = db.lock().expect("db lock");
        let request = WsRequest {
            id: "req-1".into(),
            method: "health".into(),
            params: serde_json::json!({}),
        };

        let response = dispatch_read_query(&request, &state).await;

        assert_eq!(response.id, "req-1");
        assert!(response.error.is_none());
        assert_eq!(
            response
                .result
                .expect("health response")
                .get("status")
                .and_then(serde_json::Value::as_str),
            Some("ok")
        );
    }

    fn test_http_state() -> DaemonHttpState {
        let (sender, _) = broadcast::channel(8);
        let db = Arc::new(OnceLock::new());
        DaemonHttpState {
            token: "token".into(),
            sender: sender.clone(),
            manifest: super::super::state::DaemonManifest {
                version: "18.2.3".into(),
                pid: 1,
                endpoint: "http://127.0.0.1:0".into(),
                started_at: "2026-04-04T00:00:00Z".into(),
                token_path: "/tmp/token".into(),
                sandboxed: false,
                host_bridge: super::super::state::HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
            },
            daemon_epoch: "epoch".into(),
            replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
            db: db.clone(),
            codex_controller: crate::daemon::codex_controller::CodexControllerHandle::new(
                sender.clone(),
                db.clone(),
                false,
            ),
            agent_tui_manager: crate::daemon::agent_tui::AgentTuiManagerHandle::new(
                sender, db, false,
            ),
        }
    }

    fn test_http_state_with_db() -> DaemonHttpState {
        let (sender, _) = broadcast::channel(8);
        let db = Arc::new(OnceLock::new());
        db.set(Arc::new(Mutex::new(
            super::super::db::DaemonDb::open_in_memory().expect("open in-memory db"),
        )))
        .expect("install db");
        DaemonHttpState {
            token: "token".into(),
            sender: sender.clone(),
            manifest: super::super::state::DaemonManifest {
                version: "18.2.3".into(),
                pid: 1,
                endpoint: "http://127.0.0.1:0".into(),
                started_at: "2026-04-04T00:00:00Z".into(),
                token_path: "/tmp/token".into(),
                sandboxed: false,
                host_bridge: super::super::state::HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
            },
            daemon_epoch: "epoch".into(),
            replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
            db: db.clone(),
            codex_controller: crate::daemon::codex_controller::CodexControllerHandle::new(
                sender.clone(),
                db.clone(),
                false,
            ),
            agent_tui_manager: crate::daemon::agent_tui::AgentTuiManagerHandle::new(
                sender, db, false,
            ),
        }
    }
}
