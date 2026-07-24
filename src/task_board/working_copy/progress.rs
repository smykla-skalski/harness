//! Progress reporting for working-copy obtain, plus the bridge to the
//! daemon's WebSocket broadcast.
//!
//! Obtaining a working copy is clone-only: a present copy is reused instantly
//! with no event, so the only long-running operation is the initial checkout.
//! The runtime emits coarse `Started` / `Completed` / `Failed` events - the UI
//! renders a "cloning..." state, not a precise progress bar.
//!
//! [`BroadcastProgressSink`] translates each event into a [`StreamEvent`]
//! published under [`TASK_BOARD_WORKING_COPY_PROGRESS_EVENT`]; the Monitor
//! decodes the payload into a typed value.

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use tracing::warn;

use crate::daemon::protocol::StreamEvent;

/// WS push-event name for working-copy obtain progress. Snake-case with a
/// `task_board_` prefix so subscribers can filter by prefix, matching the
/// convention used by `reviews_local_clone_progress`.
pub const TASK_BOARD_WORKING_COPY_PROGRESS_EVENT: &str = "task_board_working_copy_progress";

/// One progress event for a working-copy obtain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkingCopyProgress {
    /// The clone/checkout is starting.
    Started { repo_full_name: String },
    /// The obtain finished successfully.
    Completed {
        repo_full_name: String,
        duration: Duration,
    },
    /// The obtain failed; the UI can drop the spinner and show the error.
    Failed {
        repo_full_name: String,
        message: String,
    },
}

impl WorkingCopyProgress {
    #[must_use]
    pub fn repo_full_name(&self) -> &str {
        match self {
            Self::Started { repo_full_name }
            | Self::Completed { repo_full_name, .. }
            | Self::Failed { repo_full_name, .. } => repo_full_name,
        }
    }
}

/// Sink for progress events. Implementations bridge to the daemon's
/// WebSocket broadcast channel; tests use a Vec collector.
pub trait WorkingCopyProgressSink: Send + Sync {
    fn report(&self, event: WorkingCopyProgress);
}

/// A no-op sink for code paths that don't care about progress (CLI dry-runs,
/// tests).
#[derive(Debug, Clone, Copy)]
pub struct DiscardProgressSink;

impl WorkingCopyProgressSink for DiscardProgressSink {
    fn report(&self, _: WorkingCopyProgress) {}
}

/// Wire shape consumed by the Monitor's transport. Serialized into the
/// `StreamEvent::payload` field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum WorkingCopyProgressEventPayload {
    Started {
        repo_full_name: String,
    },
    Completed {
        repo_full_name: String,
        duration_millis: u64,
    },
    Failed {
        repo_full_name: String,
        message: String,
    },
}

impl From<WorkingCopyProgress> for WorkingCopyProgressEventPayload {
    fn from(value: WorkingCopyProgress) -> Self {
        match value {
            WorkingCopyProgress::Started { repo_full_name } => Self::Started { repo_full_name },
            WorkingCopyProgress::Completed {
                repo_full_name,
                duration,
            } => Self::Completed {
                repo_full_name,
                duration_millis: duration_millis_from(duration),
            },
            WorkingCopyProgress::Failed {
                repo_full_name,
                message,
            } => Self::Failed {
                repo_full_name,
                message,
            },
        }
    }
}

fn duration_millis_from(value: Duration) -> u64 {
    u64::try_from(value.as_millis()).unwrap_or(u64::MAX)
}

/// `WorkingCopyProgressSink` implementation that pushes every event into the
/// daemon's broadcast channel as a `StreamEvent`. Cloneable via `Arc`; safe to
/// share across `spawn_blocking` because `broadcast::Sender` is Send + Sync.
pub struct BroadcastProgressSink {
    sender: broadcast::Sender<StreamEvent>,
}

impl BroadcastProgressSink {
    #[must_use]
    pub fn new(sender: broadcast::Sender<StreamEvent>) -> Arc<Self> {
        Arc::new(Self { sender })
    }
}

impl WorkingCopyProgressSink for BroadcastProgressSink {
    fn report(&self, event: WorkingCopyProgress) {
        let payload: WorkingCopyProgressEventPayload = event.into();
        self.send_stream_event(&payload);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_serialize_error(error: &serde_json::Error) {
    warn!(
        target = "harness::task_board::working_copy",
        "failed to serialize working-copy progress event (event={TASK_BOARD_WORKING_COPY_PROGRESS_EVENT}): {error}",
    );
}

impl BroadcastProgressSink {
    fn send_stream_event(&self, payload: &WorkingCopyProgressEventPayload) {
        match build_stream_event(payload) {
            // The send result is "no active receivers", not an error - Monitor
            // subscribes/unsubscribes across launches; ignore rather than warn.
            Ok(stream_event) => {
                let _ = self.sender.send(stream_event);
            }
            Err(error) => warn_serialize_error(&error),
        }
    }
}

fn build_stream_event(
    payload: &WorkingCopyProgressEventPayload,
) -> Result<StreamEvent, serde_json::Error> {
    let payload_value = serde_json::to_value(payload)?;
    Ok(StreamEvent {
        event: TASK_BOARD_WORKING_COPY_PROGRESS_EVENT.to_string(),
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
        let payload: WorkingCopyProgressEventPayload = WorkingCopyProgress::Started {
            repo_full_name: "owner/repo".into(),
        }
        .into();
        match payload {
            WorkingCopyProgressEventPayload::Started { repo_full_name } => {
                assert_eq!(repo_full_name, "owner/repo");
            }
            _ => panic!("expected Started variant"),
        }
    }

    #[test]
    fn completed_event_carries_duration_millis_not_micros() {
        let payload: WorkingCopyProgressEventPayload = WorkingCopyProgress::Completed {
            repo_full_name: "owner/repo".into(),
            duration: Duration::from_millis(742),
        }
        .into();
        match payload {
            WorkingCopyProgressEventPayload::Completed {
                duration_millis, ..
            } => assert_eq!(duration_millis, 742),
            _ => panic!("expected Completed variant"),
        }
    }

    #[test]
    fn failed_event_preserves_message() {
        let payload: WorkingCopyProgressEventPayload = WorkingCopyProgress::Failed {
            repo_full_name: "owner/repo".into(),
            message: "auth denied".into(),
        }
        .into();
        match payload {
            WorkingCopyProgressEventPayload::Failed { message, .. } => {
                assert_eq!(message, "auth denied");
            }
            _ => panic!("expected Failed variant"),
        }
    }

    #[test]
    fn broadcast_sink_pushes_payload_into_stream_event() {
        let (sender, mut receiver) = broadcast::channel(8);
        let sink = BroadcastProgressSink::new(sender);
        sink.report(WorkingCopyProgress::Started {
            repo_full_name: "owner/repo".into(),
        });
        let event = receiver.try_recv().expect("receive");
        assert_eq!(event.event, TASK_BOARD_WORKING_COPY_PROGRESS_EVENT);
        let payload: WorkingCopyProgressEventPayload =
            serde_json::from_value(event.payload).expect("decode");
        assert!(matches!(
            payload,
            WorkingCopyProgressEventPayload::Started { .. }
        ));
    }

    #[test]
    fn broadcast_sink_drops_silently_when_no_receivers() {
        let (sender, receiver) = broadcast::channel(2);
        drop(receiver);
        let sink = BroadcastProgressSink::new(sender);
        sink.report(WorkingCopyProgress::Started {
            repo_full_name: "owner/repo".into(),
        });
    }

    #[test]
    fn wire_payload_serializes_as_tagged_json() {
        let payload = WorkingCopyProgressEventPayload::Started {
            repo_full_name: "owner/repo".into(),
        };
        let json = serde_json::to_value(&payload).expect("serialize");
        assert_eq!(json["kind"], "started");
        assert_eq!(json["repo_full_name"], "owner/repo");
    }
}
