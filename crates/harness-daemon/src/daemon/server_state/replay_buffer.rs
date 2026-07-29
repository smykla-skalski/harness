//! Shared types for the daemon's single-pass broadcast fan-out.
//!
//! The fan-out mechanism itself - `build_prepared` and `run_broadcast_fanout` -
//! stays in `crate::daemon::websocket::broadcast`, which is the sole producer
//! of these types. They live here only because [`DaemonHttpState`](
//! super::DaemonHttpState) carries them as field types.

use std::collections::VecDeque;
use std::sync::Arc;

use axum::extract::ws::Message;

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
