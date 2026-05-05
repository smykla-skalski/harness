use std::sync::Arc;

use tokio::time::sleep;
use tracing::warn;

use super::{AcpSessionSupervisor, DisconnectReason, WatchdogState};

/// Async watchdog loop. Returns the reason for firing or `None` if cancelled.
///
/// Design: the loop wakes on three events: (1) timeout expiry, (2) `record_event`
/// resets the timer via notify, (3) `exit_client_call` unpauses via notify. This
/// eliminates polling; the loop only wakes when state actually changes. While
/// paused, the loop waits indefinitely - if the client call hangs, so does the
/// watchdog (intentional: "client in call" means "don't kill it").
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub async fn watchdog_loop(supervisor: Arc<AcpSessionSupervisor>) -> Option<DisconnectReason> {
    loop {
        match supervisor.watchdog_state() {
            WatchdogState::Done => return None,
            WatchdogState::Fired => return Some(DisconnectReason::WatchdogFired),
            WatchdogState::Paused => {
                supervisor.watchdog_notify.notified().await;
                continue;
            }
            WatchdogState::Active => {}
        }

        let elapsed = supervisor.elapsed_since_last_event();
        let timeout = supervisor.config().watchdog_timeout;

        if let Some(remaining) = timeout.checked_sub(elapsed) {
            tokio::select! {
                () = sleep(remaining) => {}
                () = supervisor.watchdog_notify.notified() => continue,
            }
        }

        if supervisor.should_fire_watchdog() {
            supervisor.mark_watchdog_fired();
            warn!(
                pending_requests = supervisor.pending_request_count(),
                in_flight_calls = supervisor.in_flight_call_count(),
                elapsed_secs = supervisor.elapsed_since_last_event().as_secs(),
                timeout_secs = supervisor.config().watchdog_timeout.as_secs(),
                "watchdog fired: agent silent while daemon request pending"
            );
            return Some(DisconnectReason::WatchdogFired);
        }
    }
}
