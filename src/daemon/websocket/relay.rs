use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use axum::extract::ws::Message;
use tokio::sync::{broadcast, mpsc};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{DaemonHttpState, require_async_db};
use crate::daemon::protocol::{StreamEvent, WsPushEvent};
use crate::daemon::service;
use crate::errors::CliError;

use super::connection::ConnectionState;
use super::dispatch::ws_activity_log_level;
use super::frames::serialize_push_frames;

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

pub(crate) async fn relay_broadcast(
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

pub(crate) async fn next_relay_frames(
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
    let events: Vec<StreamEvent> = recovery_events_for_connection(connection, state).await;
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

    match require_async_db(state, "websocket recovery snapshot") {
        Ok(async_db) => build_recovery_events_async(&plan, async_db).await,
        Err(error) => recovery_events_on_error(&error),
    }
}

fn recovery_events_on_error(error: &CliError) -> Vec<StreamEvent> {
    warn_recovery_snapshot_failure(error);
    Vec::new()
}

async fn build_recovery_events_async(
    plan: &RelayRecoveryPlan,
    async_db: &AsyncDaemonDb,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    if plan.include_sessions_updated {
        append_recovery_event(
            &mut events,
            service::sessions_updated_event_async(Some(async_db)).await,
            "sessions_updated",
            None,
        );
    }
    for session_id in &plan.session_ids {
        append_recovery_event(
            &mut events,
            service::session_updated_core_event_async(session_id, Some(async_db)).await,
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
        tracing::event!(
            ws_activity_log_level(),
            event = %event.event,
            session_id = event.session_id.as_deref().unwrap_or("-"),
            seq,
            frame_count = frames.len(),
            "ws push"
        );
    }
    frames
}

#[cfg(test)]
mod tests {
    use super::super::test_support::test_http_state_with_async_db_timeline;
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
        assert_eq!(buffer.entries.front().expect("front entry").0, 2);

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

    #[tokio::test]
    async fn recovery_events_use_async_db_when_sync_db_is_unavailable() {
        let state = test_http_state_with_async_db_timeline().await;
        let connection = Arc::new(Mutex::new(ConnectionState::new()));
        {
            let mut connection_state = connection.lock().expect("connection lock");
            connection_state.global_subscription = true;
            connection_state
                .session_subscriptions
                .insert("sess-test-1".into());
        }

        let events = recovery_events_for_connection(&connection, &state).await;

        assert!(
            events.iter().any(|event| event.event == "sessions_updated"),
            "expected sessions_updated recovery event"
        );
        assert!(
            events.iter().any(|event| {
                event.event == "session_updated"
                    && event.session_id.as_deref() == Some("sess-test-1")
            }),
            "expected session_updated recovery event"
        );
    }
}
