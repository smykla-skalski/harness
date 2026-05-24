use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::http::header::{AUTHORIZATION, ORIGIN, USER_AGENT};
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::{Instant, interval as tokio_interval};
use tracing::Instrument as _;
use tracing::field::{Empty, display};
use tracing::{debug, info, warn};

use crate::daemon::http::{self, DaemonHttpState};
use crate::daemon::protocol::StreamEvent;
use crate::telemetry::{apply_parent_context_from_headers, current_trace_id, with_active_baggage};

use super::config::build_config_push_frame;
use super::dispatch::handle_message;
use super::relay::relay_broadcast;

pub(crate) struct ConnectionState {
    pub(crate) global_subscription: bool,
    pub(crate) session_subscriptions: HashSet<String>,
}

impl ConnectionState {
    pub(crate) fn new() -> Self {
        Self {
            global_subscription: false,
            session_subscriptions: HashSet::new(),
        }
    }

    pub(crate) fn should_relay(&self, event: &StreamEvent) -> bool {
        if self.global_subscription {
            return true;
        }
        if let Some(session_id) = &event.session_id {
            return self.session_subscriptions.contains(session_id);
        }
        false
    }
}

const HEADER_CLIENT_NAME: &str = "x-harness-client-name";
const HEADER_CLIENT_VERSION: &str = "x-harness-client-version";
const HEADER_CLIENT_BUNDLE_ID: &str = "x-harness-client-bundle-id";
const HEADER_CLIENT_PID: &str = "x-harness-client-pid";
const HEADER_CLIENT_LAUNCH_MODE: &str = "x-harness-client-launch-mode";
const HEADER_SEC_WEBSOCKET_PROTOCOL: &str = "sec-websocket-protocol";
const MISSING_METADATA: &str = "<missing>";
const HEADER_VALUE_LOG_LIMIT: usize = 160;

#[derive(Clone, Debug, Eq, PartialEq)]
struct WebSocketHandshakeMetadata {
    client_name: Option<String>,
    client_version: Option<String>,
    client_bundle_id: Option<String>,
    client_pid: Option<String>,
    client_launch_mode: Option<String>,
    user_agent: Option<String>,
    origin: Option<String>,
    websocket_protocol: Option<String>,
    auth_state: &'static str,
}

impl WebSocketHandshakeMetadata {
    fn from_headers(headers: &HeaderMap) -> Self {
        Self {
            client_name: header_summary(headers, HEADER_CLIENT_NAME),
            client_version: header_summary(headers, HEADER_CLIENT_VERSION),
            client_bundle_id: header_summary(headers, HEADER_CLIENT_BUNDLE_ID),
            client_pid: header_summary(headers, HEADER_CLIENT_PID),
            client_launch_mode: header_summary(headers, HEADER_CLIENT_LAUNCH_MODE),
            user_agent: header_summary(headers, USER_AGENT.as_str()),
            origin: header_summary(headers, ORIGIN.as_str()),
            websocket_protocol: header_summary(headers, HEADER_SEC_WEBSOCKET_PROTOCOL),
            auth_state: auth_header_state(headers),
        }
    }

    fn client_label(&self) -> String {
        let mut label = self
            .client_name
            .clone()
            .or_else(|| self.user_agent.clone())
            .unwrap_or_else(|| "unknown".to_string());
        if self.client_name.is_some()
            && let Some(version) = &self.client_version
        {
            label.push('/');
            label.push_str(version);
        }
        let mut details = Vec::new();
        if let Some(bundle_id) = &self.client_bundle_id {
            details.push(format!("bundle={bundle_id}"));
        }
        if let Some(pid) = &self.client_pid {
            details.push(format!("pid={pid}"));
        }
        if let Some(launch_mode) = &self.client_launch_mode {
            details.push(format!("launch={launch_mode}"));
        }
        if details.is_empty() {
            label
        } else {
            format!("{label} ({})", details.join("; "))
        }
    }

    fn record_on_span(&self, span: &tracing::Span) {
        let client = self.client_label();
        span.record("client", display(&client));
        span.record(
            "client_name",
            display(self.client_name.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "client_version",
            display(self.client_version.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "client_bundle_id",
            display(self.client_bundle_id.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "client_pid",
            display(self.client_pid.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "client_launch_mode",
            display(
                self.client_launch_mode
                    .as_deref()
                    .unwrap_or(MISSING_METADATA),
            ),
        );
        span.record(
            "user_agent",
            display(self.user_agent.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "origin",
            display(self.origin.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "websocket_protocol",
            display(
                self.websocket_protocol
                    .as_deref()
                    .unwrap_or(MISSING_METADATA),
            ),
        );
        span.record("auth_state", display(self.auth_state));
    }
}

fn header_summary(headers: &HeaderMap, name: &str) -> Option<String> {
    let raw = headers.get(name)?.to_str().ok()?.trim();
    if raw.is_empty() {
        return None;
    }
    let mut summary = raw.chars().take(HEADER_VALUE_LOG_LIMIT).collect::<String>();
    if raw.chars().count() > HEADER_VALUE_LOG_LIMIT {
        summary.push_str("...");
    }
    Some(summary)
}

fn auth_header_state(headers: &HeaderMap) -> &'static str {
    match headers.get(AUTHORIZATION) {
        None => "missing",
        Some(value) => match value.to_str() {
            Ok(raw) if raw.trim().starts_with("Bearer ") => "bearer-present",
            Ok(_) => "non-bearer",
            Err(_) => "invalid-utf8",
        },
    }
}

pub async fn ws_upgrade_handler(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    ws: WebSocketUpgrade,
) -> Response {
    let request_id = http::extract_request_id(&headers);
    let connection_span = websocket_connection_span(&request_id);
    let metadata = WebSocketHandshakeMetadata::from_headers(&headers);
    let client_label = metadata.client_label();
    metadata.record_on_span(&connection_span);
    let baggage = apply_parent_context_from_headers(&connection_span, &headers);
    if let Some(trace_id) = connection_span.in_scope(current_trace_id) {
        connection_span.record("trace_id", display(trace_id));
    }
    if let Err(response) = http::require_auth(&headers, &state) {
        connection_span.in_scope(|| warn!(client = %client_label, "websocket connection rejected"));
        return *response;
    }
    ws.on_upgrade(move |socket| async move {
        with_active_baggage(
            baggage,
            handle_connection(socket, state, client_label).instrument(connection_span.clone()),
        )
        .await;
    })
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
async fn handle_connection(socket: WebSocket, state: DaemonHttpState, client_label: String) {
    tracing::info!(client = %client_label, "websocket connection opened");
    let (mut sender, mut receiver) = socket.split();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));

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
    let inbound_client_label = client_label.clone();
    let inbound_task = tokio::spawn(async move {
        let mut dispatch_tasks = JoinSet::new();
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
                                state.clone(),
                                Arc::clone(&connection_dispatch),
                                priority_tx_dispatch.clone(),
                                &mut dispatch_tasks,
                            ) {
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
                Some(_) = dispatch_tasks.join_next(), if !dispatch_tasks.is_empty() => {}
                _ = idle_check.tick() => {
                    if last_client_message.elapsed() > Duration::from_secs(45) {
                        info!(client = %inbound_client_label, "websocket idle timeout, closing connection");
                        break;
                    }
                }
            }
        }
        dispatch_tasks.abort_all();
        while dispatch_tasks.join_next().await.is_some() {}
    });

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
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use axum::extract::ws::Message;
    use axum::http::header::{AUTHORIZATION, ORIGIN, USER_AGENT};
    use serde_json::json;
    use tokio::sync::broadcast;

    use super::super::relay::next_relay_frames;
    use super::super::test_support::{
        seed_sample_session, test_http_state, test_http_state_with_db,
    };
    use super::*;
    use crate::daemon::protocol::WsPushEvent;

    #[test]
    fn connection_state_relay_filtering() {
        let mut state = ConnectionState::new();
        let global_event = StreamEvent {
            event: "sessions_updated".into(),
            recorded_at: "2026-03-29T12:00:00Z".into(),
            session_id: None,
            payload: json!({}),
        };
        let session_event = StreamEvent {
            event: "session_updated".into(),
            recorded_at: "2026-03-29T12:00:00Z".into(),
            session_id: Some("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into()),
            payload: json!({}),
        };

        assert!(!state.should_relay(&global_event));
        assert!(!state.should_relay(&session_event));

        state
            .session_subscriptions
            .insert("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into());
        assert!(!state.should_relay(&global_event));
        assert!(state.should_relay(&session_event));

        state.global_subscription = true;
        assert!(state.should_relay(&global_event));
        assert!(state.should_relay(&session_event));
    }

    #[test]
    fn handshake_metadata_extracts_monitor_client_headers() {
        let mut headers = HeaderMap::new();
        headers.insert(
            USER_AGENT,
            "HarnessMonitor/30.32.0".parse().expect("user agent"),
        );
        headers.insert(
            HEADER_CLIENT_NAME,
            "harness-monitor".parse().expect("client name"),
        );
        headers.insert(
            HEADER_CLIENT_VERSION,
            "30.32.0".parse().expect("client version"),
        );
        headers.insert(
            HEADER_CLIENT_BUNDLE_ID,
            "io.harnessmonitor.app".parse().expect("bundle id"),
        );
        headers.insert(HEADER_CLIENT_PID, "70891".parse().expect("client pid"));
        headers.insert(
            HEADER_CLIENT_LAUNCH_MODE,
            "live".parse().expect("launch mode"),
        );
        headers.insert(ORIGIN, "app://harness-monitor".parse().expect("origin"));
        headers.insert(
            HEADER_SEC_WEBSOCKET_PROTOCOL,
            "jsonrpc".parse().expect("websocket protocol"),
        );
        headers.insert(AUTHORIZATION, "Bearer token".parse().expect("auth header"));

        let metadata = WebSocketHandshakeMetadata::from_headers(&headers);
        assert_eq!(metadata.client_name.as_deref(), Some("harness-monitor"));
        assert_eq!(metadata.client_version.as_deref(), Some("30.32.0"));
        assert_eq!(
            metadata.client_bundle_id.as_deref(),
            Some("io.harnessmonitor.app")
        );
        assert_eq!(metadata.client_pid.as_deref(), Some("70891"));
        assert_eq!(metadata.client_launch_mode.as_deref(), Some("live"));
        assert_eq!(
            metadata.user_agent.as_deref(),
            Some("HarnessMonitor/30.32.0")
        );
        assert_eq!(metadata.origin.as_deref(), Some("app://harness-monitor"));
        assert_eq!(metadata.websocket_protocol.as_deref(), Some("jsonrpc"));
        assert_eq!(metadata.auth_state, "bearer-present");
        assert_eq!(
            metadata.client_label(),
            "harness-monitor/30.32.0 (bundle=io.harnessmonitor.app; pid=70891; launch=live)"
        );
    }

    #[test]
    fn handshake_metadata_tracks_auth_state_without_leaking_tokens() {
        let missing = WebSocketHandshakeMetadata::from_headers(&HeaderMap::new());
        assert_eq!(missing.auth_state, "missing");

        let mut non_bearer_headers = HeaderMap::new();
        non_bearer_headers.insert(AUTHORIZATION, "Basic abc".parse().expect("auth header"));
        let non_bearer = WebSocketHandshakeMetadata::from_headers(&non_bearer_headers);
        assert_eq!(non_bearer.auth_state, "non-bearer");
        assert_eq!(non_bearer.client_label(), "unknown");
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
                session_id: Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into()),
                payload: json!({}),
            })
            .expect("send first event");
        sender
            .send(StreamEvent {
                event: "session_updated".into(),
                recorded_at: "2026-04-13T19:00:01Z".into(),
                session_id: Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into()),
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
        seed_sample_session(&state);

        let connection = Arc::new(Mutex::new(ConnectionState::new()));
        connection
            .lock()
            .expect("connection lock")
            .session_subscriptions
            .insert("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into());

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
        assert_eq!(
            push.session_id.as_deref(),
            Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
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
            tokio::time::sleep(Duration::from_mins(1)).await;
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

        let (priority_tx, _) = mpsc::channel::<Message>(1);
        let mut dispatch_tasks = JoinSet::new();
        let action = handle_incoming_message(
            Message::Ping(vec![4, 5, 6].into()),
            state,
            connection,
            priority_tx,
            &mut dispatch_tasks,
        );

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
}
