//! Loop-control predicates for the observe subsystem.
//!
//! Two responsibilities live in the observe loop and they have different
//! gates. Naming both predicates next to each other makes the next drift
//! visible in review:
//!
//! - **Liveness ticking** keeps the daemon's heartbeat fresh for the on-call
//!   operator and keeps agent liveness sync running while the session is
//!   joinable. Wide gate: any liveness-eligible status.
//! - **Observation scanning** records non-empty findings for the reader who
//!   triages them. Narrow gate: `Active` only - there is nothing meaningful
//!   to scan in a session that has no leader yet or has lost its leader.
//!
//! The CLI watch loop is observation-only (calls [`should_observe`]). The
//! daemon-owned async loop runs while [`should_tick_liveness`] holds and
//! only performs observation work when [`should_observe`] also holds.

use crate::session::types::SessionStatus;

/// Whether the observe loop should keep ticking for liveness sync.
///
/// Mirrors the set of statuses the daemon supervisor treats as
/// joinable / liveness-eligible.
#[must_use]
pub const fn should_tick_liveness(status: SessionStatus) -> bool {
    status.is_liveness_eligible()
}

/// Whether the observe loop should perform an observation scan.
///
/// Only `Active` qualifies. `AwaitingLeader` and `LeaderlessDegraded`
/// can keep liveness running but have nothing useful to observe.
#[must_use]
pub const fn should_observe(status: SessionStatus) -> bool {
    matches!(status, SessionStatus::Active)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn liveness_predicate_matches_joinable_statuses() {
        assert!(should_tick_liveness(SessionStatus::AwaitingLeader));
        assert!(should_tick_liveness(SessionStatus::Active));
        assert!(should_tick_liveness(SessionStatus::LeaderlessDegraded));
    }

    #[test]
    fn liveness_predicate_rejects_terminal_and_paused_statuses() {
        assert!(!should_tick_liveness(SessionStatus::Paused));
        assert!(!should_tick_liveness(SessionStatus::Ended));
    }

    #[test]
    fn observe_predicate_only_admits_active() {
        assert!(should_observe(SessionStatus::Active));
    }

    #[test]
    fn observe_predicate_rejects_non_active_statuses() {
        assert!(!should_observe(SessionStatus::AwaitingLeader));
        assert!(!should_observe(SessionStatus::LeaderlessDegraded));
        assert!(!should_observe(SessionStatus::Paused));
        assert!(!should_observe(SessionStatus::Ended));
    }

    #[test]
    fn observe_implies_liveness_for_every_status() {
        for status in [
            SessionStatus::AwaitingLeader,
            SessionStatus::Active,
            SessionStatus::Paused,
            SessionStatus::LeaderlessDegraded,
            SessionStatus::Ended,
        ] {
            if should_observe(status) {
                assert!(
                    should_tick_liveness(status),
                    "should_observe must imply should_tick_liveness for {status:?}"
                );
            }
        }
    }

    #[test]
    fn liveness_predicate_matches_session_status_liveness_eligibility() {
        for status in [
            SessionStatus::AwaitingLeader,
            SessionStatus::Active,
            SessionStatus::Paused,
            SessionStatus::LeaderlessDegraded,
            SessionStatus::Ended,
        ] {
            assert_eq!(should_tick_liveness(status), status.is_liveness_eligible());
        }
    }

    #[test]
    fn predicates_disagree_on_awaiting_leader_and_degraded() {
        for status in [
            SessionStatus::AwaitingLeader,
            SessionStatus::LeaderlessDegraded,
        ] {
            assert!(should_tick_liveness(status));
            assert!(!should_observe(status));
        }
    }
}
