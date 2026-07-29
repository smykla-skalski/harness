//! Single-pass broadcast fan-out.
//!
//! Producers publish a [`StreamEvent`] once on the shared broadcast channel. A
//! lone fan-out task is the sole subscriber: it assigns the connection-
//! independent `seq`, serializes the wire frames exactly once, and re-publishes
//! a shared [`PreparedBroadcast`] (an `Arc`) to every connection relay. The
//! per-connection cost then collapses to a refcount bump plus a cheap
//! `Bytes`-backed frame clone, instead of a per-subscriber deep clone and two
//! JSON serializations.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use axum::extract::ws::Message;
use tokio::sync::broadcast;

use crate::daemon::protocol::{StreamEvent, WsPushEvent};

use super::frames::serialize_push_frames;

/// A broadcast event prepared exactly once at fan-out and shared by every
/// relay task.
///
/// `seq` is assigned once so the frame is identical for every connection.
/// `ws_frames` are the chunked WebSocket push frames; their `Message::Text`
/// payloads are `Bytes`-backed, so cloning them per connection is a refcount
/// bump rather than a copy. `sse_data` is the matching Server-Sent-Events data
/// body, memoized so SSE subscribers reuse the same serialized bytes.
#[derive(Debug)]
pub struct PreparedBroadcast {
    pub(crate) seq: u64,
    pub(crate) event_name: String,
    pub(crate) session_id: Option<String>,
    pub(crate) ws_frames: Vec<Message>,
    pub(crate) sse_data: String,
}

/// Bounded ring of recently broadcast events, keyed by their assigned `seq`.
///
/// The fan-out task appends each event exactly once. Relay tasks read the ring
/// on a `Lagged` overflow to replay small gaps before falling back to a full
/// recovery snapshot.
#[derive(Debug)]
pub struct ReplayBuffer {
    entries: VecDeque<Arc<PreparedBroadcast>>,
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

    /// Reserve the next monotonic sequence number for an event about to be
    /// serialized. The fan-out task is the only writer, so reservation and the
    /// later [`ReplayBuffer::store`] stay ordered.
    pub(crate) fn reserve_seq(&mut self) -> u64 {
        let seq = self.next_seq;
        self.next_seq += 1;
        seq
    }

    pub(crate) fn store(&mut self, prepared: Arc<PreparedBroadcast>) {
        if self.entries.len() >= self.capacity {
            self.entries.pop_front();
        }
        self.entries.push_back(prepared);
    }

    /// Return every buffered event newer than `last_seq`, or `None` when the
    /// gap predates the oldest retained entry (the caller must then rebuild a
    /// full recovery snapshot).
    #[must_use]
    pub(crate) fn replay_since(&self, last_seq: u64) -> Option<Vec<Arc<PreparedBroadcast>>> {
        let oldest = self.entries.front().map(|prepared| prepared.seq)?;
        if last_seq < oldest.saturating_sub(1) {
            return None;
        }
        Some(
            self.entries
                .iter()
                .filter(|prepared| prepared.seq > last_seq)
                .cloned()
                .collect(),
        )
    }

    #[must_use]
    pub fn current_seq(&self) -> u64 {
        self.next_seq.saturating_sub(1)
    }
}

/// Serialize a single event into its shared wire form and append it to the
/// replay buffer. Runs once per event in the fan-out task (or once per
/// recovery event in a relay task), never per subscriber.
pub(crate) fn build_prepared(
    event: StreamEvent,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
) -> Arc<PreparedBroadcast> {
    let sse_data = serde_json::to_string(&event).unwrap_or_default();
    let seq = replay_buffer
        .lock()
        .expect("replay buffer lock")
        .reserve_seq();
    let push = WsPushEvent {
        event: event.event.clone(),
        recorded_at: event.recorded_at.clone(),
        session_id: event.session_id.clone(),
        payload: event.payload.clone(),
        seq,
    };
    let ws_frames = serialize_push_frames(&push).unwrap_or_default();
    let prepared = Arc::new(PreparedBroadcast {
        seq,
        event_name: event.event,
        session_id: event.session_id,
        ws_frames,
        sse_data,
    });
    replay_buffer
        .lock()
        .expect("replay buffer lock")
        .store(Arc::clone(&prepared));
    prepared
}

/// Drain the raw producer channel and republish prepared events.
///
/// Spawned once per daemon. Being the sole consumer of the raw channel means
/// the broadcast deep-clone of each `StreamEvent` happens a single time here,
/// independent of how many clients are connected.
pub(crate) async fn run_broadcast_fanout(
    mut raw_rx: broadcast::Receiver<StreamEvent>,
    prepared_tx: broadcast::Sender<Arc<PreparedBroadcast>>,
    replay_buffer: Arc<Mutex<ReplayBuffer>>,
) {
    loop {
        match raw_rx.recv().await {
            Ok(event) => {
                let prepared = build_prepared(event, &replay_buffer);
                // A send error only means no connections are subscribed yet;
                // the event is still recorded in the replay buffer.
                let _ = prepared_tx.send(prepared);
            }
            Err(broadcast::error::RecvError::Lagged(skipped)) => {
                warn_fanout_lagged(skipped);
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_fanout_lagged(skipped: u64) {
    tracing::warn!(skipped, "broadcast fan-out lagged; events dropped");
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn sample_event(seq_hint: &str) -> StreamEvent {
        StreamEvent {
            event: "session_updated".into(),
            recorded_at: format!("2026-05-29T00:00:0{seq_hint}Z"),
            session_id: Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into()),
            payload: json!({ "n": seq_hint }),
        }
    }

    #[test]
    fn build_prepared_assigns_monotonic_seq_and_stores_once() {
        let buffer = Arc::new(Mutex::new(ReplayBuffer::new(4)));
        let first = build_prepared(sample_event("1"), &buffer);
        let second = build_prepared(sample_event("2"), &buffer);

        assert_eq!(first.seq, 1);
        assert_eq!(second.seq, 2);
        assert_eq!(buffer.lock().expect("lock").current_seq(), 2);
        assert!(!first.ws_frames.is_empty());
        assert!(first.sse_data.contains("session_updated"));
        // The wire frame carries the seq; the SSE body does not.
        assert!(!first.sse_data.contains("\"seq\""));
    }

    #[test]
    fn replay_since_returns_gap_then_none_when_evicted() {
        let buffer = Arc::new(Mutex::new(ReplayBuffer::new(3)));
        for hint in ["1", "2", "3", "4"] {
            build_prepared(sample_event(hint), &buffer);
        }

        let guard = buffer.lock().expect("lock");
        // Capacity 3 evicted seq 1, so a gap from 0 cannot be served.
        assert!(guard.replay_since(0).is_none());
        let replayed = guard.replay_since(2).expect("replay should succeed");
        assert_eq!(
            replayed
                .iter()
                .map(|prepared| prepared.seq)
                .collect::<Vec<_>>(),
            vec![3, 4]
        );
    }
}
