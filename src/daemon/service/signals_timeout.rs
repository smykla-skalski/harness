use super::{Duration, state};

pub(super) fn warn_active_signal_delivery_timeout(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    timeout: Duration,
) {
    state::append_event_best_effort(
        "warn",
        &active_signal_delivery_timeout_message(session_id, agent_id, signal_id, timeout),
    );
    log_active_signal_delivery_timeout(session_id, agent_id, signal_id, timeout);
}

fn active_signal_delivery_timeout_message(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    timeout: Duration,
) -> String {
    format!(
        "session '{session_id}' signal '{signal_id}' to agent '{agent_id}' stayed pending after active TUI wake-up for {} ms",
        timeout.as_millis()
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "structured tracing macro expansion inflates this simple logging helper"
)]
fn log_active_signal_delivery_timeout(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    timeout: Duration,
) {
    tracing::warn!(
        session_id,
        agent_id,
        signal_id,
        timeout_ms = timeout.as_millis(),
        "active TUI signal delivery timed out"
    );
}
