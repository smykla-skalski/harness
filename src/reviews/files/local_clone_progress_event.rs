//! Bridge from `LocalCloneProgressSink` to the daemon's WebSocket broadcast.
//!
//! Wraps a `tokio::sync::broadcast::Sender<StreamEvent>` and translates
//! each `LocalCloneProgress` event into a `StreamEvent` payload published
//! under the `reviews_local_clone_progress` event name. The
//! Monitor side subscribes via its existing transport and decodes the
//! payload into a typed `LocalCloneProgress` value.
//!
//! Lives next to `local_clone_runtime` so the producer + the on-the-wire
//! shape sit in the same module - any future change to the progress
//! enum reaches both sides through one PR.

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use tracing::warn;

use crate::daemon::protocol::StreamEvent;

use super::local_clone_runtime::{LocalCloneOperation, LocalCloneProgress, LocalCloneProgressSink};

/// WS push-event name. Matches the convention used by the existing
/// `sessions_updated` / `session_extensions` events (snake-case, no dot
/// inside the event name itself; the `reviews.` prefix here
/// is part of the event identifier so subscribers can filter by prefix).
pub const REVIEWS_LOCAL_CLONE_PROGRESS_EVENT: &str = "reviews_local_clone_progress";

/// Wire shape consumed by the Monitor's transport. Serialized into the
/// `StreamEvent::payload` field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LocalCloneProgressEventPayload {
    Started {
        repo_full_name: String,
        operation: LocalCloneOperationWire,
    },
    Completed {
        repo_full_name: String,
        operation: LocalCloneOperationWire,
        duration_millis: u64,
    },
    Failed {
        repo_full_name: String,
        operation: LocalCloneOperationWire,
        message: String,
    },
}

/// String-serialized operation enum so the wire shape is stable across
/// future internal renames.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocalCloneOperationWire {
    Clone,
    Fetch,
}

impl From<LocalCloneOperation> for LocalCloneOperationWire {
    fn from(value: LocalCloneOperation) -> Self {
        match value {
            LocalCloneOperation::Clone => Self::Clone,
            LocalCloneOperation::Fetch => Self::Fetch,
        }
    }
}

impl From<LocalCloneProgress> for LocalCloneProgressEventPayload {
    fn from(value: LocalCloneProgress) -> Self {
        match value {
            LocalCloneProgress::Started {
                repo_full_name,
                operation,
            } => Self::Started {
                repo_full_name,
                operation: operation.into(),
            },
            LocalCloneProgress::Completed {
                repo_full_name,
                operation,
                duration,
            } => Self::Completed {
                repo_full_name,
                operation: operation.into(),
                duration_millis: duration_millis_from(duration),
            },
            LocalCloneProgress::Failed {
                repo_full_name,
                operation,
                message,
            } => Self::Failed {
                repo_full_name,
                operation: operation.into(),
                message,
            },
        }
    }
}

fn duration_millis_from(value: Duration) -> u64 {
    u64::try_from(value.as_millis()).unwrap_or(u64::MAX)
}

/// `LocalCloneProgressSink` implementation that pushes every event into
/// the daemon's broadcast channel as a `StreamEvent`.
///
/// Cloneable via Arc; safe to share across the runtime's `spawn_blocking`
/// boundary because `broadcast::Sender` is itself Send + Sync + Clone.
pub struct BroadcastProgressSink {
    sender: broadcast::Sender<StreamEvent>,
}

impl BroadcastProgressSink {
    #[must_use]
    pub fn new(sender: broadcast::Sender<StreamEvent>) -> Arc<Self> {
        Arc::new(Self { sender })
    }
}

impl LocalCloneProgressSink for BroadcastProgressSink {
    fn report(&self, event: LocalCloneProgress) {
        let payload: LocalCloneProgressEventPayload = event.into();
        self.send_stream_event(&payload);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_serialize_error(error: &serde_json::Error) {
    warn!(
        target = "harness::reviews::files",
        "failed to serialize local-clone progress event (event={REVIEWS_LOCAL_CLONE_PROGRESS_EVENT}): {error}",
    );
}

impl BroadcastProgressSink {
    fn send_stream_event(&self, payload: &LocalCloneProgressEventPayload) {
        match build_stream_event(payload) {
            Ok(stream_event) => {
                // The send result is "no active receivers", not an error.
                // We expect bursts of subscribe/unsubscribe across Monitor
                // launches; ignore the result rather than warn-spam.
                let _ = self.sender.send(stream_event);
            }
            Err(error) => warn_serialize_error(&error),
        }
    }
}

fn build_stream_event(
    payload: &LocalCloneProgressEventPayload,
) -> Result<StreamEvent, serde_json::Error> {
    let payload_value = serde_json::to_value(payload)?;
    Ok(StreamEvent {
        event: REVIEWS_LOCAL_CLONE_PROGRESS_EVENT.to_string(),
        recorded_at: chrono::Utc::now().to_rfc3339(),
        session_id: None,
        payload: payload_value,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn started_event_round_trips_through_wire_shape() {
        let progress = LocalCloneProgress::Started {
            repo_full_name: "owner/repo".into(),
            operation: LocalCloneOperation::Clone,
        };
        let payload: LocalCloneProgressEventPayload = progress.into();
        match payload {
            LocalCloneProgressEventPayload::Started {
                repo_full_name,
                operation,
            } => {
                assert_eq!(repo_full_name, "owner/repo");
                assert_eq!(operation, LocalCloneOperationWire::Clone);
            }
            _ => panic!("expected Started variant"),
        }
    }

    #[test]
    fn completed_event_carries_duration_millis_not_micros() {
        let progress = LocalCloneProgress::Completed {
            repo_full_name: "owner/repo".into(),
            operation: LocalCloneOperation::Fetch,
            duration: Duration::from_millis(742),
        };
        let payload: LocalCloneProgressEventPayload = progress.into();
        match payload {
            LocalCloneProgressEventPayload::Completed {
                duration_millis,
                operation,
                ..
            } => {
                assert_eq!(duration_millis, 742);
                assert_eq!(operation, LocalCloneOperationWire::Fetch);
            }
            _ => panic!("expected Completed variant"),
        }
    }

    #[test]
    fn failed_event_preserves_message() {
        let progress = LocalCloneProgress::Failed {
            repo_full_name: "owner/repo".into(),
            operation: LocalCloneOperation::Clone,
            message: "auth denied".into(),
        };
        let payload: LocalCloneProgressEventPayload = progress.into();
        match payload {
            LocalCloneProgressEventPayload::Failed { message, .. } => {
                assert_eq!(message, "auth denied");
            }
            _ => panic!("expected Failed variant"),
        }
    }

    #[test]
    fn broadcast_sink_pushes_payload_into_stream_event() {
        let (sender, mut receiver) = broadcast::channel(8);
        let sink = BroadcastProgressSink::new(sender);
        sink.report(LocalCloneProgress::Started {
            repo_full_name: "owner/repo".into(),
            operation: LocalCloneOperation::Clone,
        });
        let event = receiver.try_recv().expect("receive");
        assert_eq!(event.event, REVIEWS_LOCAL_CLONE_PROGRESS_EVENT);
        let payload: LocalCloneProgressEventPayload =
            serde_json::from_value(event.payload).expect("decode");
        assert!(matches!(
            payload,
            LocalCloneProgressEventPayload::Started { .. }
        ));
    }

    #[test]
    fn broadcast_sink_drops_silently_when_no_receivers() {
        let (sender, _receiver) = broadcast::channel(2);
        drop(_receiver);
        let sink = BroadcastProgressSink::new(sender);
        // Should not panic / log error.
        sink.report(LocalCloneProgress::Started {
            repo_full_name: "owner/repo".into(),
            operation: LocalCloneOperation::Clone,
        });
    }

    #[test]
    fn wire_payload_serializes_as_tagged_json() {
        let payload = LocalCloneProgressEventPayload::Started {
            repo_full_name: "owner/repo".into(),
            operation: LocalCloneOperationWire::Clone,
        };
        let json = serde_json::to_value(&payload).expect("serialize");
        assert_eq!(json["kind"], "started");
        assert_eq!(json["operation"], "clone");
        assert_eq!(json["repo_full_name"], "owner/repo");
    }

    #[test]
    fn event_name_constant_matches_dotted_prefix_convention() {
        // The event name follows snake_case + dotted prefix; subscribers
        // can filter by "reviews_" prefix without parsing.
        assert!(REVIEWS_LOCAL_CLONE_PROGRESS_EVENT.starts_with("reviews_local_clone_progress"));
    }
}
