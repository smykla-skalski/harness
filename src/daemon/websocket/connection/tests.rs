use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::ws::Message;
use serde_json::json;
use tokio::sync::broadcast;

use super::super::broadcast::{PreparedBroadcast, ReplayBuffer, build_prepared};
use super::super::relay::next_relay_frames;
use super::super::test_support::{seed_sample_session, test_http_state, test_http_state_with_db};
use super::*;
use crate::daemon::protocol::WsPushEvent;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{
    RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration,
};

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
        state.clone(),
        connection,
        priority_tx,
        &mut dispatch_tasks,
    )
    .await;

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
async fn remote_websocket_caps_in_flight_dispatch_tasks() {
    let mut state = test_http_state_with_db();
    state.auth_mode = crate::daemon::http::DaemonHttpAuthMode::Remote;
    let mut config = crate::daemon::http::RemoteRequestLimitConfig::default();
    config.max_websocket_in_flight_requests = 1;
    state.remote_request_limits =
        Some(crate::daemon::http::RemoteRequestLimits::new(config).expect("remote request limits"));
    let registration = RemoteClientRegistration::new_for_tests(
        "viewer",
        "Viewer",
        "macos",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        "token-viewer-abcdefghijklmnopqrstuvwxyz0123456789",
        "2026-07-12T09:00:00Z",
    )
    .expect("remote registration");
    let remote_client = {
        let db = state.db.get().expect("db slot").lock().expect("db lock");
        db.register_remote_client(&registration)
            .expect("register remote client");
        db.list_remote_clients()
            .expect("list remote clients")
            .into_iter()
            .next()
            .expect("stored remote client")
    };
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(remote_client)));
    let (priority_tx, _) = mpsc::channel::<Message>(1);
    let mut dispatch_tasks = JoinSet::new();
    dispatch_tasks.spawn(std::future::pending::<()>());

    let action = handle_incoming_message(
        Message::Text(
            serde_json::json!({
                "id": "overloaded-request",
                "method": crate::daemon::protocol::ws_methods::PING,
            })
            .to_string()
            .into(),
        ),
        state.clone(),
        connection,
        priority_tx,
        &mut dispatch_tasks,
    )
    .await;

    assert_eq!(dispatch_tasks.len(), 1, "overload must not spawn work");
    let IncomingMessageAction::RespondBatch(frames) = action else {
        panic!("overload should return a bounded error response");
    };
    let Message::Text(text) = &frames[0] else {
        panic!("overload response should be JSON text");
    };
    let response: serde_json::Value = serde_json::from_str(text).expect("overload response JSON");
    assert_eq!(response["id"], "overloaded-request");
    assert_eq!(response["error"]["code"], "REMOTE_LIMITS");
    assert_eq!(response["error"]["status_code"], 429);
    let audit = state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("load remote audits")
        .into_iter()
        .find(|event| event.request_id.as_deref() == Some("overloaded-request"))
        .expect("overload authorization audit");
    assert_eq!(audit.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(audit.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(
        audit.error_detail.as_deref(),
        Some("remote WebSocket in-flight request limit reached")
    );
}
