use std::time::Duration;

use tokio::spawn;
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio::time::interval as tokio_interval;

use crate::workspace::utc_now;

use super::protocol::StreamEvent;
use super::snapshot;

/// Spawn the daemon's periodic refresh loop for SSE subscribers.
#[must_use]
pub fn spawn_watch_loop(
    sender: broadcast::Sender<StreamEvent>,
    interval: Duration,
) -> JoinHandle<()> {
    spawn(async move {
        let mut ticker = tokio_interval(interval);
        let mut previous_payload = String::new();
        loop {
            ticker.tick().await;
            let Ok(sessions) = snapshot::session_summaries(true) else {
                continue;
            };
            let Ok(encoded) = serde_json::to_string(&sessions) else {
                continue;
            };
            if encoded == previous_payload {
                continue;
            }
            previous_payload.clone_from(&encoded);
            let _ = sender.send(StreamEvent {
                event: "sessions_updated".into(),
                recorded_at: utc_now(),
                session_id: None,
                payload: serde_json::from_str(&encoded).unwrap_or_else(|_| serde_json::json!([])),
            });
        }
    })
}
