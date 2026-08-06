use serde::Serialize;
use serde_json::Value;
use tokio::sync::broadcast;

use super::{StreamEvent, utc_now};
use harness_kernel::errors::{CliError, CliErrorKind};

pub(crate) fn stream_event<T: Serialize>(
    event: &str,
    session_id: Option<&str>,
    payload: T,
) -> Result<StreamEvent, CliError> {
    Ok(StreamEvent {
        event: event.to_string(),
        recorded_at: utc_now(),
        session_id: session_id.map(ToString::to_string),
        payload: serialize_event_payload(payload, event)?,
    })
}

pub(crate) fn serialize_event_payload<T: Serialize>(
    payload: T,
    event: &str,
) -> Result<Value, CliError> {
    serde_json::to_value(payload).map_err(|error| {
        CliErrorKind::workflow_io(format!("serialize daemon push '{event}': {error}")).into()
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) fn broadcast_event(
    sender: &broadcast::Sender<StreamEvent>,
    event: Result<StreamEvent, CliError>,
    event_name: &str,
    session_id: Option<&str>,
) {
    match event {
        Ok(payload) => {
            let receiver_count = sender.receiver_count();
            let _ = sender.send(payload);
            tracing::debug!(
                event = event_name,
                session_id = session_id.unwrap_or("-"),
                receiver_count,
                "broadcast event sent"
            );
        }
        Err(error) => {
            warn_broadcast_failure(&error.to_string(), event_name, session_id.unwrap_or("-"));
        }
    }
}

/// Emit a warning for a failed broadcast event.
///
/// Uses `tracing::Event::dispatch` directly because the `tracing::warn!`
/// macro expansion generates cognitive complexity 8 in clippy's analysis,
/// which exceeds the pedantic threshold of 7. See tokio-rs/tracing#553.
pub(crate) fn warn_broadcast_failure(error_message: &str, event_name: &str, session: &str) {
    use tracing::callsite::DefaultCallsite;
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata, callsite::Identifier};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "warn",
        "harness::daemon::service",
        Level::WARN,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, Identifier(&CALLSITE)),
        Kind::EVENT,
    );

    let message = format!(
        "failed to build daemon push event '{event_name}': {error_message} (session={session})"
    );
    let values: &[Option<&dyn Value>] = &[Some(&message.as_str())];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}
