use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Extension;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::http::HeaderMap;
use axum::response::Response;
use futures_util::stream::SplitStream;
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::{Instant, interval as tokio_interval};
use tracing::Instrument as _;
use tracing::field::{Empty, display};
use tracing::{debug, info, warn};

use crate::daemon::db::db_error;
use crate::daemon::http::{self, DaemonConnectInfo, DaemonHttpState};
#[cfg(test)]
use crate::daemon::protocol::StreamEvent;
use crate::daemon::remote_identity::RemoteStoredClient;
use crate::errors::CliError;
use crate::telemetry::{apply_parent_context_from_headers, current_trace_id, with_active_baggage};

use super::config::build_config_push_frame;
use super::connection_metadata::WebSocketHandshakeMetadata;
use super::dispatch::{handle_message, handle_overloaded_message};
use super::relay::relay_broadcast;

pub(crate) struct ConnectionState {
    pub(crate) global_subscription: bool,
    pub(crate) session_subscriptions: HashSet<String>,
    remote_client: Option<RemoteStoredClient>,
    remote_addr: Option<String>,
    /// Highest broadcast `seq` this connection has relayed. On a `Lagged`
    /// overflow the relay replays the buffer from here before falling back to a
    /// full recovery snapshot.
    pub(crate) last_relayed_seq: u64,
}

impl ConnectionState {
    #[cfg(test)]
    pub(crate) fn new() -> Self {
        Self::new_with_remote_client(None, None)
    }

    #[cfg(test)]
    pub(crate) fn new_remote(remote_client: RemoteStoredClient) -> Self {
        Self::new_with_remote_client(Some(remote_client), None)
    }

    fn new_with_remote_client(
        remote_client: Option<RemoteStoredClient>,
        remote_addr: Option<String>,
    ) -> Self {
        Self {
            global_subscription: false,
            session_subscriptions: HashSet::new(),
            remote_client,
            remote_addr,
            last_relayed_seq: 0,
        }
    }

    pub(crate) fn remote_client(&self) -> Option<&RemoteStoredClient> {
        self.remote_client.as_ref()
    }

    pub(crate) fn remote_addr(&self) -> Option<&str> {
        self.remote_addr.as_deref()
    }

    fn replace_remote_client(&mut self, client: RemoteStoredClient) {
        self.remote_client = Some(client);
    }

    #[cfg(test)]
    pub(crate) fn should_relay(&self, event: &StreamEvent) -> bool {
        self.should_relay_session(event.session_id.as_deref())
    }

    /// Subscription filter keyed on the event's `session_id`. A `None` scope is
    /// a global event, relayed only to global subscribers.
    pub(crate) fn should_relay_session(&self, session_id: Option<&str>) -> bool {
        if self.global_subscription {
            return true;
        }
        if let Some(session_id) = session_id {
            return self.session_subscriptions.contains(session_id);
        }
        false
    }
}

pub(crate) async fn ws_upgrade_handler(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    connect_info: Option<Extension<ConnectInfo<DaemonConnectInfo>>>,
    ws: WebSocketUpgrade,
) -> Response {
    let request_id = http::extract_request_id(&headers);
    let connection_span = websocket_connection_span(&request_id);
    let metadata = WebSocketHandshakeMetadata::from_headers(&headers);
    let client_label = metadata.client_label();
    metadata.record_on_span(&connection_span);
    let baggage = apply_parent_context_from_headers(&connection_span, &headers);
    record_trace_id_on_span(&connection_span);
    let remote_client = match http::authenticated_remote_client(&headers, &state) {
        Ok(client) => client,
        Err(response) => {
            record_rejected_connection(&connection_span, &client_label);
            return *response;
        }
    };
    let (ws, remote_connection_permit) = match http::prepare_remote_websocket_upgrade(ws, &state) {
        Ok(prepared) => prepared,
        Err(response) => return *response,
    };
    let remote_addr =
        connect_info.map(|Extension(ConnectInfo(info))| info.remote_addr().ip().to_string());
    ws.on_upgrade(move |socket| async move {
        let _remote_connection_permit = remote_connection_permit;
        with_active_baggage(
            baggage,
            handle_connection(socket, state, client_label, remote_client, remote_addr)
                .instrument(connection_span.clone()),
        )
        .await;
    })
}

fn record_trace_id_on_span(connection_span: &tracing::Span) {
    if let Some(trace_id) = connection_span.in_scope(current_trace_id) {
        connection_span.record("trace_id", display(trace_id));
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn record_rejected_connection(connection_span: &tracing::Span, client_label: &str) {
    connection_span.in_scope(|| warn!(client = %client_label, "websocket connection rejected"));
}

fn websocket_connection_span(request_id: &str) -> tracing::Span {
    tracing::info_span!(
        parent: None,
        "harness.daemon.websocket.connection",
        otel.name = "GET /v1/ws",
        otel.kind = "server",
        request_id = %request_id,
        "http.request.method" = "GET",
        "url.path" = "/v1/ws",
        "network.protocol.name" = "websocket",
        client = Empty,
        client_name = Empty,
        client_version = Empty,
        client_bundle_id = Empty,
        client_pid = Empty,
        client_launch_mode = Empty,
        user_agent = Empty,
        origin = Empty,
        websocket_protocol = Empty,
        auth_state = Empty,
        trace_id = Empty
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn handle_connection(
    socket: WebSocket,
    state: DaemonHttpState,
    client_label: String,
    remote_client: Option<RemoteStoredClient>,
    remote_addr: Option<String>,
) {
    tracing::info!(client = %client_label, "websocket connection opened");
    let (mut sender, receiver) = socket.split();
    let connection = Arc::new(Mutex::new(ConnectionState::new_with_remote_client(
        remote_client,
        remote_addr,
    )));

    let (priority_tx, mut priority_rx) = mpsc::channel::<Message>(64);
    let (bulk_tx, mut bulk_rx) = mpsc::channel::<Message>(256);

    // Push the configuration frame before subscribing to broadcasts so it is
    // guaranteed to be the first frame delivered to the client.
    if let Some(frame) = build_config_push_frame()
        && priority_tx.send(frame).await.is_err()
    {
        tracing::debug!("websocket closed before configuration frame could be sent");
        return;
    }

    let broadcast_rx = state.prepared_sender.subscribe();

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

    let inbound_task = spawn_inbound_task(
        receiver,
        state,
        connection,
        priority_tx,
        client_label.clone(),
    );

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
    tracing::info!(client = %client_label, "websocket connection closed");
}

fn spawn_inbound_task(
    mut receiver: SplitStream<WebSocket>,
    state: DaemonHttpState,
    connection: Arc<Mutex<ConnectionState>>,
    priority_tx: mpsc::Sender<Message>,
    client_label: String,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut dispatch_tasks = JoinSet::new();
        let mut last_client_message = Instant::now();
        let mut idle_check = tokio_interval(Duration::from_secs(15));
        let mut credential_check = tokio_interval(Duration::from_secs(5));
        credential_check.tick().await;

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
                                state.clone(),
                                Arc::clone(&connection),
                                priority_tx.clone(),
                                &mut dispatch_tasks,
                            ) {
                                IncomingMessageAction::ContinueLoop => {}
                                IncomingMessageAction::CloseConnection => break,
                                IncomingMessageAction::RespondBatch(frames) => {
                                    for frame in frames {
                                        if priority_tx.send(frame).await.is_err() {
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
                Some(_) = dispatch_tasks.join_next(), if !dispatch_tasks.is_empty() => {}
                _ = credential_check.tick(), if state.auth_mode == http::DaemonHttpAuthMode::Remote => {
                    match refresh_remote_connection_client(&state, &connection) {
                        Ok(Some(_)) => {}
                        Ok(None) => {
                            info!(client = %client_label, "remote websocket credentials invalidated, closing connection");
                            break;
                        }
                        Err(error) => {
                            warn!(client = %client_label, %error, "remote websocket credential validation failed, closing connection");
                            break;
                        }
                    }
                }
                _ = idle_check.tick() => {
                    if last_client_message.elapsed() > Duration::from_secs(45) {
                        info!(client = %client_label, "websocket idle timeout, closing connection");
                        break;
                    }
                }
            }
        }
        dispatch_tasks.abort_all();
        while dispatch_tasks.join_next().await.is_some() {}
    })
}

pub(crate) fn refresh_remote_connection_client(
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Result<Option<RemoteStoredClient>, CliError> {
    let authenticated = connection
        .lock()
        .map_err(|_| db_error("remote websocket connection state is unavailable"))?
        .remote_client()
        .cloned();
    let Some(authenticated) = authenticated else {
        return Ok(None);
    };
    let db = state
        .db
        .get()
        .ok_or_else(|| db_error("remote authentication store is unavailable"))?;
    let current = db
        .lock()
        .map_err(|_| db_error("remote authentication store is unavailable"))?
        .validate_remote_client_session(&authenticated)?;
    if let Some(client) = current.as_ref() {
        connection
            .lock()
            .map_err(|_| db_error("remote websocket connection state is unavailable"))?
            .replace_remote_client(client.clone());
    }
    Ok(current)
}

pub(crate) async fn await_connection_tasks(
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

pub(crate) enum IncomingMessageAction {
    ContinueLoop,
    CloseConnection,
    RespondBatch(Vec<Message>),
}

pub(crate) fn incoming_message_counts_as_activity(message: &Message) -> bool {
    matches!(
        message,
        Message::Text(_) | Message::Binary(_) | Message::Ping(_) | Message::Pong(_)
    )
}

pub(crate) fn handle_incoming_message(
    message: Message,
    state: DaemonHttpState,
    connection: Arc<Mutex<ConnectionState>>,
    priority_tx: mpsc::Sender<Message>,
    dispatch_tasks: &mut JoinSet<()>,
) -> IncomingMessageAction {
    match message {
        Message::Text(text) => {
            while dispatch_tasks.try_join_next().is_some() {}
            if let Some(rejection) = remote_dispatch_rejection(&state, dispatch_tasks.len()) {
                return IncomingMessageAction::RespondBatch(handle_overloaded_message(
                    &text,
                    &state,
                    &connection,
                    rejection.status,
                    rejection.message,
                ));
            }
            spawn_text_dispatch(
                text.to_string(),
                state,
                connection,
                priority_tx,
                dispatch_tasks,
            );
            IncomingMessageAction::ContinueLoop
        }
        Message::Ping(payload) => IncomingMessageAction::RespondBatch(vec![Message::Pong(payload)]),
        Message::Close(_) => IncomingMessageAction::CloseConnection,
        Message::Binary(_) | Message::Pong(_) => IncomingMessageAction::ContinueLoop,
    }
}

struct RemoteDispatchRejection {
    status: u16,
    message: &'static str,
}

fn remote_dispatch_rejection(
    state: &DaemonHttpState,
    in_flight: usize,
) -> Option<RemoteDispatchRejection> {
    if state.auth_mode == http::DaemonHttpAuthMode::Local {
        return None;
    }
    let Some(limits) = state.remote_request_limits.as_ref() else {
        return Some(RemoteDispatchRejection {
            status: 503,
            message: "remote request limits are unavailable",
        });
    };
    (in_flight >= limits.config().max_websocket_in_flight_requests).then_some(
        RemoteDispatchRejection {
            status: 429,
            message: "remote WebSocket in-flight request limit reached",
        },
    )
}

fn spawn_text_dispatch(
    text: String,
    state: DaemonHttpState,
    connection: Arc<Mutex<ConnectionState>>,
    priority_tx: mpsc::Sender<Message>,
    dispatch_tasks: &mut JoinSet<()>,
) {
    dispatch_tasks.spawn(async move {
        for frame in Box::pin(handle_message(&text, &state, &connection)).await {
            if priority_tx.send(frame).await.is_err() {
                break;
            }
        }
    });
}

#[cfg(test)]
mod tests;
