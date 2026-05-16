use std::sync::{Arc, Mutex};

use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};
use tracing_subscriber::registry;

use crate::errors::{CliError, CliErrorKind};

use super::support::record_policy_load_failure;

#[derive(Clone, Default)]
struct CapturedEvent {
    target: String,
    event_field: Option<String>,
    message: Option<String>,
    level: String,
}

struct CaptureVisitor<'a> {
    captured: &'a mut CapturedEvent,
}

impl Visit for CaptureVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let rendered = format!("{value:?}");
        let trimmed = rendered.trim_matches('"').to_string();
        if field.name() == "message" {
            self.captured.message = Some(trimmed);
        } else if field.name() == "event" {
            self.captured.event_field = Some(trimmed);
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "event" {
            self.captured.event_field = Some(value.to_string());
        } else if field.name() == "message" {
            self.captured.message = Some(value.to_string());
        }
    }
}

struct CaptureLayer {
    events: Arc<Mutex<Vec<CapturedEvent>>>,
}

impl<S> Layer<S> for CaptureLayer
where
    S: Subscriber,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let mut captured = CapturedEvent {
            target: metadata.target().to_string(),
            level: metadata.level().to_string(),
            ..CapturedEvent::default()
        };
        let mut visitor = CaptureVisitor {
            captured: &mut captured,
        };
        event.record(&mut visitor);
        self.events
            .lock()
            .expect("event capture lock")
            .push(captured);
    }
}

#[test]
fn policy_load_failure_emits_audit_event() {
    let events = Arc::new(Mutex::new(Vec::new()));
    let subscriber = registry().with(CaptureLayer {
        events: Arc::clone(&events),
    });

    let error: CliError = CliErrorKind::workflow_io("simulated load failure").into();
    tracing::subscriber::with_default(subscriber, || {
        record_policy_load_failure(&error);
    });

    let captured = events.lock().expect("captured events").clone();
    let audit_event = captured
        .iter()
        .find(|event| event.event_field.as_deref() == Some("harness_audit_policy_load_failure"))
        .expect("audit event emitted");
    assert_eq!(audit_event.level, "ERROR");
    assert_eq!(audit_event.target, "harness::policy_audit");
    assert!(
        audit_event
            .message
            .as_deref()
            .is_some_and(|message| message.contains("falling back to built-in")),
        "unexpected audit message: {:?}",
        audit_event.message,
    );
}
