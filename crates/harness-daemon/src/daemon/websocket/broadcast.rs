//! Single-pass broadcast fan-out.
//!
//! Producers publish a [`StreamEvent`] once on the shared broadcast channel. A
//! lone fan-out task is the sole subscriber: it assigns the connection-
//! independent `seq`, serializes the wire frames exactly once, and re-publishes
//! a shared [`PreparedBroadcast`] (an `Arc`) to every connection relay. The
//! per-connection cost then collapses to a refcount bump plus a cheap
//! `Bytes`-backed frame clone, instead of a per-subscriber deep clone and two
//! JSON serializations.
//!
//! [`PreparedBroadcast`] and [`ReplayBuffer`] themselves are defined in
//! `crate::daemon::server_state`, which [`DaemonHttpState`](
//! crate::daemon::http::DaemonHttpState) carries them through; this module
//! owns only the fan-out mechanism that produces and consumes them.

use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

use crate::daemon::protocol::{StreamEvent, WsPushEvent};
pub use crate::daemon::server_state::{PreparedBroadcast, ReplayBuffer};

use super::frames::serialize_push_frames;

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
