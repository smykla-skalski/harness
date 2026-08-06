use std::fmt;

use crate::append_event_best_effort;

/// Severity of a single managed-agent wake-decision telemetry record.
#[derive(Clone, Copy)]
pub enum WakeEventLevel {
    Info,
    Warn,
    Error,
}

impl WakeEventLevel {
    fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warn => "warn",
            Self::Error => "error",
        }
    }
}

/// Single source-of-truth for managed-agent wake-decision telemetry. Fans the
/// same payload into both observation pipelines so the line operators grep in
/// `events.jsonl` matches what `tracing` emits for unified-log queries:
///
///   - `tracing::{info,warn,error}!` at `target = "harness::wake"` with a
///     structured `kind` field and the rendered `acp_wake.<kind> k=v ...`
///     message.
///   - `append_event_best_effort(level, message)` to `events.jsonl` so the
///     diagnostics surface and any downstream regex consumer see the same
///     string.
///
/// TRIPWIRE: if a second programmatic consumer parses these strings
/// (per-reason metrics, alerting, dashboards), promote to a typed event enum
/// so the schema is enforced by the compiler instead of by greppers.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn record_wake_event(
    level: WakeEventLevel,
    kind: &'static str,
    fields: &[(&'static str, &dyn fmt::Display)],
) {
    use std::fmt::Write as _;
    let mut message = format!("acp_wake.{kind}");
    for (key, value) in fields {
        let _ = write!(message, " {key}={value}");
    }
    match level {
        WakeEventLevel::Info => {
            tracing::info!(target: "harness::wake", kind, %message);
        }
        WakeEventLevel::Warn => {
            tracing::warn!(target: "harness::wake", kind, %message);
        }
        WakeEventLevel::Error => {
            tracing::error!(target: "harness::wake", kind, %message);
        }
    }
    append_event_best_effort(level.as_str(), &message);
}
