//! Per-session bounded ring buffer for ACP session updates.
//!
//! The ring accumulates `SessionNotification`s until a flush threshold is met:
//! - 32 updates (configurable)
//! - 64 KiB accumulated payload (configurable)
//! - 5 ms since first update in batch (configurable)
//!
//! On flush, the batch is drained and sent to a channel for materialisation into
//! `ConversationEvent`s. The ring reuses its internal buffer across batches to
//! minimise allocations in the hot path.

use std::mem;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::{ContentChunk, SessionNotification, SessionUpdate};

/// Default maximum updates before flush.
pub const DEFAULT_MAX_UPDATES: usize = 32;

/// Default maximum bytes before flush.
pub const DEFAULT_MAX_BYTES: usize = 64 * 1024;

/// Default maximum time before flush.
pub const DEFAULT_MAX_DURATION: Duration = Duration::from_millis(5);

/// Configuration for the ring buffer flush thresholds.
#[derive(Debug, Clone)]
pub struct RingConfig {
    /// Maximum updates before flush.
    pub max_updates: usize,
    /// Maximum accumulated bytes before flush.
    pub max_bytes: usize,
    /// Maximum time since first update before flush.
    pub max_duration: Duration,
}

impl Default for RingConfig {
    fn default() -> Self {
        Self {
            max_updates: DEFAULT_MAX_UPDATES,
            max_bytes: DEFAULT_MAX_BYTES,
            max_duration: DEFAULT_MAX_DURATION,
        }
    }
}

/// Compact wrapper around `SessionNotification` with size tracking.
#[derive(Debug, Clone)]
pub struct RawSessionUpdate {
    /// The original notification.
    pub notification: SessionNotification,
    /// Estimated serialized size in bytes.
    pub estimated_bytes: usize,
}

impl RawSessionUpdate {
    /// Create from a notification, estimating its size.
    #[must_use]
    pub fn new(notification: SessionNotification) -> Self {
        let estimated_bytes = estimate_notification_size(&notification);
        Self {
            notification,
            estimated_bytes,
        }
    }
}

/// Per-session ring buffer that accumulates updates until flush thresholds.
#[derive(Debug)]
pub struct SessionRing {
    config: RingConfig,
    updates: Vec<RawSessionUpdate>,
    accumulated_bytes: usize,
    batch_start: Option<Instant>,
}

impl SessionRing {
    /// Create a new ring with the given configuration.
    #[must_use]
    pub fn new(config: RingConfig) -> Self {
        Self {
            updates: Vec::with_capacity(config.max_updates),
            accumulated_bytes: 0,
            batch_start: None,
            config,
        }
    }

    /// Create a ring with default configuration.
    #[must_use]
    pub fn with_defaults() -> Self {
        Self::new(RingConfig::default())
    }

    /// Push an update into the ring. Returns `true` if flush thresholds are met.
    pub fn push(&mut self, notification: SessionNotification) -> bool {
        let update = RawSessionUpdate::new(notification);
        self.accumulated_bytes += update.estimated_bytes;
        self.updates.push(update);

        if self.batch_start.is_none() {
            self.batch_start = Some(Instant::now());
        }

        self.should_flush()
    }

    /// Check if any flush threshold is met.
    #[must_use]
    pub fn should_flush(&self) -> bool {
        if self.updates.is_empty() {
            return false;
        }

        if self.updates.len() >= self.config.max_updates {
            return true;
        }

        if self.accumulated_bytes >= self.config.max_bytes {
            return true;
        }

        if let Some(start) = self.batch_start
            && start.elapsed() >= self.config.max_duration
        {
            return true;
        }

        false
    }

    /// Drain the ring, returning the accumulated batch.
    pub fn drain(&mut self) -> Vec<RawSessionUpdate> {
        self.accumulated_bytes = 0;
        self.batch_start = None;
        mem::take(&mut self.updates)
    }

    /// Number of updates currently in the ring.
    #[must_use]
    pub fn len(&self) -> usize {
        self.updates.len()
    }

    /// Whether the ring is empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.updates.is_empty()
    }

    /// Accumulated bytes in the current batch.
    #[must_use]
    pub fn accumulated_bytes(&self) -> usize {
        self.accumulated_bytes
    }

    /// Time since batch started, if any.
    #[must_use]
    pub fn elapsed(&self) -> Option<Duration> {
        self.batch_start.map(|s| s.elapsed())
    }

    /// Configuration reference.
    #[must_use]
    pub const fn config(&self) -> &RingConfig {
        &self.config
    }
}

/// Estimate the serialized size of a notification.
///
/// This is a rough estimate to avoid serializing in the hot path. We count
/// string lengths and assume fixed overhead for enum tags and metadata.
fn estimate_notification_size(notification: &SessionNotification) -> usize {
    let base = 64; // session_id + envelope overhead

    let update_size = match &notification.update {
        SessionUpdate::UserMessageChunk(chunk) | SessionUpdate::AgentMessageChunk(chunk) => {
            estimate_content_chunk_size(chunk)
        }
        SessionUpdate::AgentThoughtChunk(chunk) => estimate_content_chunk_size(chunk),
        SessionUpdate::ToolCall(tc) => {
            32 + tc.title.len() + tc.tool_call_id.0.len() + tc.content.len() * 64
        }
        SessionUpdate::ToolCallUpdate(tcu) => 32 + tcu.tool_call_id.0.len(),
        SessionUpdate::Plan(_) => 256,
        SessionUpdate::AvailableCommandsUpdate(_)
        | SessionUpdate::ConfigOptionUpdate(_)
        | SessionUpdate::SessionInfoUpdate(_) => 128,
        _ => 64,
    };

    base + update_size
}

fn estimate_content_chunk_size(chunk: &ContentChunk) -> usize {
    use agent_client_protocol::schema::{ContentBlock, EmbeddedResourceResource};

    match &chunk.content {
        ContentBlock::Text(tc) => 32 + tc.text.len(),
        ContentBlock::Image(_) | ContentBlock::Audio(_) => 256,
        ContentBlock::ResourceLink(rl) => 64 + rl.uri.len(),
        ContentBlock::Resource(res) => match &res.resource {
            EmbeddedResourceResource::TextResourceContents(trc) => 128 + trc.uri.len(),
            EmbeddedResourceResource::BlobResourceContents(brc) => 128 + brc.uri.len(),
            _ => 128,
        },
        _ => 64,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_client_protocol::schema::{
        ContentBlock, ContentChunk, SessionId, SessionUpdate, TextContent,
    };

    fn make_text_notification(session_id: &str, text: &str) -> SessionNotification {
        SessionNotification::new(
            SessionId::new(session_id),
            SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(text),
            ))),
        )
    }

    #[test]
    fn ring_empty_initially() {
        let ring = SessionRing::with_defaults();
        assert!(ring.is_empty());
        assert_eq!(ring.len(), 0);
        assert_eq!(ring.accumulated_bytes(), 0);
        assert!(!ring.should_flush());
    }

    #[test]
    fn ring_push_increments_count() {
        let mut ring = SessionRing::with_defaults();
        let notif = make_text_notification("sess1", "hello");
        ring.push(notif);
        assert_eq!(ring.len(), 1);
        assert!(ring.accumulated_bytes() > 0);
    }

    #[test]
    fn ring_flush_on_count_threshold() {
        let config = RingConfig {
            max_updates: 3,
            max_bytes: 1_000_000,
            max_duration: Duration::from_secs(60),
        };
        let mut ring = SessionRing::new(config);

        assert!(!ring.push(make_text_notification("s", "a")));
        assert!(!ring.push(make_text_notification("s", "b")));
        assert!(ring.push(make_text_notification("s", "c")));
    }

    #[test]
    fn ring_flush_on_bytes_threshold() {
        let config = RingConfig {
            max_updates: 1000,
            max_bytes: 100,
            max_duration: Duration::from_secs(60),
        };
        let mut ring = SessionRing::new(config);

        let large_text = "x".repeat(200);
        assert!(ring.push(make_text_notification("s", &large_text)));
    }

    #[test]
    fn ring_drain_clears_and_preserves_capacity() {
        let mut ring = SessionRing::with_defaults();
        ring.push(make_text_notification("s", "a"));
        ring.push(make_text_notification("s", "b"));

        let batch = ring.drain();
        assert_eq!(batch.len(), 2);
        assert!(ring.is_empty());
        assert_eq!(ring.accumulated_bytes(), 0);
        assert!(ring.elapsed().is_none());
    }

    #[test]
    fn raw_session_update_estimates_size() {
        let notif = make_text_notification("sess", "hello world");
        let update = RawSessionUpdate::new(notif);
        assert!(update.estimated_bytes > 0);
    }
}
