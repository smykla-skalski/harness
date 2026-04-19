use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{Instant, interval as tokio_interval};
use tracing::Instrument as _;
use tracing::field::{Empty, display};
use tracing::{debug, info};

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

pub async fn ws_upgrade_handler(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    ws: WebSocketUpgrade,
) -> Response {
    if let Err(response) = http::require_auth(&headers, &state) {
        return *response;
    }
    let request_id = headers
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_string();
    let connection_span = websocket_connection_span(&request_id);
    let baggage = apply_parent_context_from_headers(&connection_span, &headers);
    if let Some(trace_id) = connection_span.in_scope(current_trace_id) {
        connection_span.record("trace_id", display(trace_id));
    }
    ws.on_upgrade(move |socket| async move {
        with_active_baggage(
            baggage,
            handle_connection(socket, state).instrument(connection_span.clone()),
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
        trace_id = Empty
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn handle_connection(socket: WebSocket, state: DaemonHttpState) {
    tracing::info!("websocket connection opened");
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
                            match Box::pin(handle_incoming_message(
                                message,
                                &state,
                                &connection_dispatch,
                            ))
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

pub(crate) async fn handle_incoming_message(
    message: Message,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> IncomingMessageAction {
    match message {
        Message::Text(text) => IncomingMessageAction::RespondBatch(
            Box::pin(handle_message(&text, state, connection)).await,
        ),
        Message::Ping(payload) => IncomingMessageAction::RespondBatch(vec![Message::Pong(payload)]),
        Message::Close(_) => IncomingMessageAction::CloseConnection,
        Message::Binary(_) | Message::Pong(_) => IncomingMessageAction::ContinueLoop,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use axum::extract::ws::Message;
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
            session_id: Some("sess-1".into()),
            payload: json!({}),
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
        seed_sample_session(&state);

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
}
