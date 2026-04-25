use serde::Serialize;
use serde_json::Value;

use crate::daemon::protocol::{CodexRunSnapshot, StreamEvent};
use crate::workspace::utc_now;

pub(super) fn codex_event<T: Serialize>(
    event: &str,
    snapshot: &CodexRunSnapshot,
    payload: &T,
) -> Option<StreamEvent> {
    let payload = codex_event_payload(event, payload)?;
    Some(StreamEvent {
        event: event.to_string(),
        recorded_at: utc_now(),
        session_id: Some(snapshot.session_id.clone()),
        payload,
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn codex_event_payload<T: Serialize>(event: &str, payload: &T) -> Option<Value> {
    match serde_json::to_value(payload) {
        Ok(payload) => Some(payload),
        Err(error) => {
            tracing::warn!(%error, event, "failed to serialize codex controller event");
            None
        }
    }
}
