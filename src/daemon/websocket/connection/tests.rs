use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::ws::Message;
use axum::http::header::{AUTHORIZATION, ORIGIN, USER_AGENT};
use serde_json::json;
use tokio::sync::broadcast;

use super::super::broadcast::{PreparedBroadcast, ReplayBuffer, build_prepared};
use super::super::relay::next_relay_frames;
use super::super::test_support::{seed_sample_session, test_http_state, test_http_state_with_db};
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
async fn next_relay_frames_recovers_sessions_updated_when_buffer_misses_gap() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    connection
        .lock()
        .expect("connection lock")
        .global_subscription = true;

    // Record the dropped events in a throwaway buffer so the connection's
    // own replay buffer cannot serve the gap, forcing a full recovery.
    let dropped = Arc::new(Mutex::new(ReplayBuffer::new(8)));
    let (sender, _) = broadcast::channel::<Arc<PreparedBroadcast>>(1);
    let mut receiver = sender.subscribe();
    sender
        .send(build_prepared(
            StreamEvent {
                event: "session_updated".into(),
                recorded_at: "2026-04-13T19:00:00Z".into(),
                session_id: Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into()),
                payload: json!({}),
            },
            &dropped,
        ))
        .expect("send first event");
    sender
        .send(build_prepared(
            StreamEvent {
                event: "session_updated".into(),
                recorded_at: "2026-04-13T19:00:01Z".into(),
                session_id: Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into()),
                payload: json!({}),
            },
            &dropped,
        ))
        .expect("send second event");

    let frames = next_relay_frames(&mut receiver, &connection, &state.replay_buffer, &state).await;
    let Message::Text(text) = &frames.expect("recovery frames")[0] else {
        panic!("expected inline websocket push frame");
    };
    let push: WsPushEvent = serde_json::from_str(text).expect("deserialize websocket push frame");

    assert_eq!(push.event, "sessions_updated");
    assert!(push.session_id.is_none());
}

#[tokio::test]
async fn next_relay_frames_recovers_session_snapshot_when_buffer_misses_gap() {
    let state = test_http_state_with_db();
    seed_sample_session(&state);

    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    connection
        .lock()
        .expect("connection lock")
        .session_subscriptions
        .insert("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into());

    let dropped = Arc::new(Mutex::new(ReplayBuffer::new(8)));
    let (sender, _) = broadcast::channel::<Arc<PreparedBroadcast>>(1);
    let mut receiver = sender.subscribe();
    sender
        .send(build_prepared(
            StreamEvent {
                event: "sessions_updated".into(),
                recorded_at: "2026-04-13T19:00:00Z".into(),
                session_id: None,
                payload: json!({}),
            },
            &dropped,
        ))
        .expect("send first event");
    sender
        .send(build_prepared(
            StreamEvent {
                event: "sessions_updated".into(),
                recorded_at: "2026-04-13T19:00:01Z".into(),
                session_id: None,
                payload: json!({}),
            },
            &dropped,
        ))
        .expect("send second event");

    let frames = next_relay_frames(&mut receiver, &connection, &state.replay_buffer, &state).await;
    let Message::Text(text) = &frames.expect("recovery frames")[0] else {
        panic!("expected inline websocket push frame");
    };
    let push: WsPushEvent = serde_json::from_str(text).expect("deserialize websocket push frame");

    assert_eq!(push.event, "session_updated");
    assert_eq!(
        push.session_id.as_deref(),
        Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
    );
}

#[tokio::test]
async fn next_relay_frames_replays_buffered_events_after_small_gap() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    connection
        .lock()
        .expect("connection lock")
        .global_subscription = true;

    // Events still held in the connection's replay buffer are re-sent
    // verbatim on a small gap, with no database recovery rebuild.
    let (sender, _) = broadcast::channel::<Arc<PreparedBroadcast>>(1);
    let mut receiver = sender.subscribe();
    for recorded_at in ["2026-04-13T19:00:00Z", "2026-04-13T19:00:01Z"] {
        sender
            .send(build_prepared(
                StreamEvent {
                    event: "session_updated".into(),
                    recorded_at: recorded_at.into(),
                    session_id: Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into()),
                    payload: json!({}),
                },
                &state.replay_buffer,
            ))
            .expect("send event");
    }

    let frames = next_relay_frames(&mut receiver, &connection, &state.replay_buffer, &state)
        .await
        .expect("replayed frames");
    let Message::Text(text) = &frames[0] else {
        panic!("expected inline websocket push frame");
    };
    let push: WsPushEvent = serde_json::from_str(text).expect("deserialize websocket push frame");

    assert_eq!(push.event, "session_updated");
    assert_eq!(
        push.session_id.as_deref(),
        Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
    );
    assert_eq!(push.seq, 1);
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
