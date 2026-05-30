use std::collections::BTreeSet;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::Duration;

use tokio::time::Instant;

use crate::daemon::agent_acp::AcpAgentInspectResponse;

/// Coalescing window for `acp_inspect` pushes. A storm of ACP trigger events
/// (one `acp_events` per streamed message batch) collapses into a single
/// inspect rebuild + broadcast per session per window.
pub(super) const ACP_INSPECT_DEBOUNCE: Duration = Duration::from_millis(150);

/// Batches ACP inspect refresh requests so a burst of trigger events produces
/// one flush per `window`, not one inspect rebuild + broadcast per event.
pub(super) struct InspectCoalescer {
    window: Duration,
    pending: BTreeSet<String>,
    deadline: Option<Instant>,
}

impl InspectCoalescer {
    pub(super) fn new(window: Duration) -> Self {
        Self {
            window,
            pending: BTreeSet::new(),
            deadline: None,
        }
    }

    /// Queue a session for the next coalesced flush.
    ///
    /// The flush deadline is armed once per batch - when the pending set
    /// transitions out of idle - so the flush lands within a bounded `window`
    /// even under a continuous trigger stream. A sliding reset on every mark
    /// could be starved by a steady stream and never flush.
    pub(super) fn mark(&mut self, session_id: String, now: Instant) {
        let was_idle = self.deadline.is_none();
        self.pending.insert(session_id);
        if was_idle {
            self.deadline = Some(now + self.window);
        }
    }

    /// The instant the current batch should flush, if any session is pending.
    pub(super) fn flush_deadline(&self) -> Option<Instant> {
        self.deadline
    }

    /// Take the pending session ids and disarm the deadline. The next `mark`
    /// starts a fresh window.
    pub(super) fn drain(&mut self) -> BTreeSet<String> {
        self.deadline = None;
        std::mem::take(&mut self.pending)
    }
}

/// Stable content fingerprint of an inspect response, used to skip redundant
/// `acp_inspect` pushes when nothing the UI renders has changed.
///
/// Monotonic clock and refresh-only fields are deliberately excluded -
/// `uptime_ms`, `prompt_deadline_remaining_ms`, each snapshot's
/// `last_update_at`, and the response `daemon_perceived_now` tick on every
/// rebuild, so including them would defeat the dedup during a streaming
/// response when nothing else has moved.
pub(super) fn inspect_content_fingerprint(response: &AcpAgentInspectResponse) -> u64 {
    let mut hasher = DefaultHasher::new();
    response.available.hash(&mut hasher);
    response.issue_message.hash(&mut hasher);
    response.agents.len().hash(&mut hasher);
    for agent in &response.agents {
        agent.acp_id.hash(&mut hasher);
        agent.session_id.hash(&mut hasher);
        agent.agent_id.hash(&mut hasher);
        agent.display_name.hash(&mut hasher);
        agent.pid.hash(&mut hasher);
        agent.pgid.hash(&mut hasher);
        agent.process_key.hash(&mut hasher);
        agent.last_client_call_at.hash(&mut hasher);
        agent.watchdog_state.hash(&mut hasher);
        agent.permission_mode.hash(&mut hasher);
        agent.permission_log_path.hash(&mut hasher);
        agent.pending_permissions.hash(&mut hasher);
        agent.permission_queue_depth.hash(&mut hasher);
        agent.terminal_count.hash(&mut hasher);
    }
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::{ACP_INSPECT_DEBOUNCE, InspectCoalescer, inspect_content_fingerprint};
    use crate::daemon::agent_acp::{AcpAgentInspectResponse, AcpAgentInspectSnapshot};
    use std::time::Duration;
    use tokio::time::Instant;

    fn snapshot(session_id: &str) -> AcpAgentInspectSnapshot {
        AcpAgentInspectSnapshot {
            acp_id: "acp-1".to_string(),
            session_id: session_id.to_string(),
            agent_id: "agent-1".to_string(),
            display_name: "agent-1".to_string(),
            pid: 1,
            pgid: 1,
            process_key: "key".to_string(),
            uptime_ms: 1,
            last_update_at: "2026-04-29T00:00:00Z".to_string(),
            last_client_call_at: None,
            watchdog_state: "active".to_string(),
            permission_mode: String::new(),
            permission_log_path: None,
            pending_permissions: 0,
            permission_queue_depth: 0,
            terminal_count: 0,
            prompt_deadline_remaining_ms: 0,
        }
    }

    fn response(snapshots: Vec<AcpAgentInspectSnapshot>) -> AcpAgentInspectResponse {
        AcpAgentInspectResponse {
            agents: snapshots,
            daemon_perceived_now: Some("2026-04-29T00:00:00Z".to_string()),
            available: true,
            issue_message: None,
        }
    }

    #[tokio::test(start_paused = true)]
    async fn mark_arms_deadline_once_per_batch() {
        let mut coalescer = InspectCoalescer::new(ACP_INSPECT_DEBOUNCE);
        let start = Instant::now();
        assert_eq!(coalescer.flush_deadline(), None);

        coalescer.mark("session-a".to_string(), start);
        let armed = coalescer.flush_deadline();
        assert_eq!(armed, Some(start + ACP_INSPECT_DEBOUNCE));

        // A later mark within the same batch does not push the deadline out.
        coalescer.mark("session-b".to_string(), start + Duration::from_millis(50));
        assert_eq!(coalescer.flush_deadline(), armed);
    }

    #[tokio::test(start_paused = true)]
    async fn drain_returns_pending_and_rearms_next_batch() {
        let mut coalescer = InspectCoalescer::new(ACP_INSPECT_DEBOUNCE);
        let start = Instant::now();
        coalescer.mark("session-b".to_string(), start);
        coalescer.mark("session-a".to_string(), start);
        coalescer.mark("session-a".to_string(), start);

        let drained = coalescer.drain();
        assert_eq!(
            drained.into_iter().collect::<Vec<_>>(),
            vec!["session-a".to_string(), "session-b".to_string()]
        );
        assert_eq!(coalescer.flush_deadline(), None);

        let later = start + Duration::from_secs(1);
        coalescer.mark("session-c".to_string(), later);
        assert_eq!(
            coalescer.flush_deadline(),
            Some(later + ACP_INSPECT_DEBOUNCE)
        );
    }

    #[test]
    fn fingerprint_ignores_monotonic_clock_fields() {
        let base = response(vec![snapshot("session-a")]);
        let mut ticked = snapshot("session-a");
        ticked.uptime_ms = 99_999;
        ticked.last_update_at = "2026-04-29T01:00:00Z".to_string();
        ticked.prompt_deadline_remaining_ms = 1234;
        let mut ticked_response = response(vec![ticked]);
        ticked_response.daemon_perceived_now = Some("2026-04-29T02:00:00Z".to_string());

        assert_eq!(
            inspect_content_fingerprint(&base),
            inspect_content_fingerprint(&ticked_response)
        );
    }

    #[test]
    fn fingerprint_tracks_rendered_field_changes() {
        let base = response(vec![snapshot("session-a")]);

        let mut watchdog = snapshot("session-a");
        watchdog.watchdog_state = "paused".to_string();
        assert_ne!(
            inspect_content_fingerprint(&base),
            inspect_content_fingerprint(&response(vec![watchdog]))
        );

        let mut permissions = snapshot("session-a");
        permissions.pending_permissions = 3;
        assert_ne!(
            inspect_content_fingerprint(&base),
            inspect_content_fingerprint(&response(vec![permissions]))
        );

        assert_ne!(
            inspect_content_fingerprint(&base),
            inspect_content_fingerprint(&response(vec![snapshot("session-b")]))
        );
    }
}
