//! Recording seam for real enforced policy decisions.
//!
//! The synchronous action-gating hot path evaluates a `PolicyDecision` for
//! every enforced action and historically discarded it. This module captures
//! each decision through a process-global sink so the daemon can persist a
//! durable feed, which the "replay this draft against what actually happened"
//! confidence feature reads back.
//!
//! The sink mirrors the `gate_cache` cold-read seam: `task_board` stays free of
//! any `crate::daemon` dependency. The daemon installs a sink at boot that
//! forwards each record to an async database writer. When no sink is installed
//! (CLI, tests), `record_policy_decision` is a no-op, so the gating hot path
//! never pays for recording outside the daemon.

use std::sync::OnceLock;

use uuid::Uuid;

use crate::task_board::{PolicyDecision, PolicyInput};

/// One real policy evaluation captured at the enforced gate.
///
/// `revision` is the enforced document revision at decision time; `enforced`
/// records whether the decision blocked a real mutation (anything other than
/// allow). `canvas_id` records the originating canvas, set by the recording
/// seam from the gate cache so replay can scope the feed to one canvas's own
/// history; it is `None` only for legacy rows recorded before provenance existed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedPolicyDecision {
    pub id: String,
    pub recorded_at: String,
    pub canvas_id: Option<String>,
    pub revision: u64,
    pub input: PolicyInput,
    pub decision: PolicyDecision,
    pub visited_node_ids: Vec<String>,
    pub source: String,
    pub enforced: bool,
}

impl RecordedPolicyDecision {
    /// Build a record for `decision` over `input`, minting the id and
    /// timestamp. `enforced` is derived from the decision (allow = not
    /// enforced).
    #[must_use]
    pub fn new(
        revision: u64,
        input: PolicyInput,
        decision: PolicyDecision,
        visited_node_ids: Vec<String>,
        source: impl Into<String>,
    ) -> Self {
        let enforced = !decision.is_allow();
        Self {
            id: format!("policy-decision-{}", Uuid::new_v4().simple()),
            recorded_at: chrono::Utc::now().to_rfc3339(),
            canvas_id: None,
            revision,
            input,
            decision,
            visited_node_ids,
            source: source.into(),
            enforced,
        }
    }

    /// Attach the originating canvas id. The recording seam sets this from the
    /// gate cache so the feed carries decision provenance; [`Self::new`] leaves
    /// it `None`.
    #[must_use]
    pub fn with_canvas_id(mut self, canvas_id: Option<String>) -> Self {
        self.canvas_id = canvas_id;
        self
    }

    /// Stable `snake_case` tag for the decision variant, stored as its own
    /// column so the feed can be filtered without decoding the decision payload.
    #[must_use]
    pub const fn decision_tag(&self) -> &'static str {
        match self.decision {
            PolicyDecision::Allow { .. } => "allow",
            PolicyDecision::Deny { .. } => "deny",
            PolicyDecision::RequireHuman { .. } => "require_human",
            PolicyDecision::RequireConsensus { .. } => "require_consensus",
            PolicyDecision::DryRunOnly { .. } => "dry_run_only",
        }
    }
}

type DecisionSink = Box<dyn Fn(RecordedPolicyDecision) + Send + Sync>;

static DECISION_SINK: OnceLock<DecisionSink> = OnceLock::new();

/// Install the process-global decision sink. Called once at daemon boot; a
/// second call is ignored so tests and re-entrant boots stay safe.
pub(crate) fn install_decision_sink(sink: DecisionSink) {
    let _ = DECISION_SINK.set(sink);
}

/// Forward `decision` to the installed sink, or drop it when none is installed.
///
/// The sink contract is fire-and-forget: it must not block the synchronous
/// gating path, so the daemon's sink only enqueues onto an unbounded channel.
pub(crate) fn record_policy_decision(decision: RecordedPolicyDecision) {
    if let Some(sink) = DECISION_SINK.get() {
        sink(decision);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::task_board::{PolicyAction, PolicyReasonCode};

    fn allow_decision() -> PolicyDecision {
        PolicyDecision::Allow {
            reason_code: PolicyReasonCode::DefaultAllow,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    }

    fn deny_decision() -> PolicyDecision {
        PolicyDecision::Deny {
            reason_code: PolicyReasonCode::ChecksNotGreen,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    }

    fn sample_input() -> PolicyInput {
        PolicyInput {
            workflow: None,
            action: PolicyAction::MergePr,
            subject: Default::default(),
            evidence: Default::default(),
            evaluated_at: None,
            approvals: Vec::new(),
        }
    }

    #[test]
    fn new_marks_allow_as_not_enforced_and_deny_as_enforced() {
        let allow =
            RecordedPolicyDecision::new(7, sample_input(), allow_decision(), vec![], "test");
        assert!(!allow.enforced);
        assert_eq!(allow.decision_tag(), "allow");
        assert_eq!(allow.revision, 7);
        assert!(allow.id.starts_with("policy-decision-"));
        assert!(allow.canvas_id.is_none());

        let deny = RecordedPolicyDecision::new(7, sample_input(), deny_decision(), vec![], "test");
        assert!(deny.enforced);
        assert_eq!(deny.decision_tag(), "deny");
    }

    #[test]
    fn with_canvas_id_attaches_provenance() {
        let record =
            RecordedPolicyDecision::new(1, sample_input(), allow_decision(), vec![], "test")
                .with_canvas_id(Some("canvas-7".to_owned()));
        assert_eq!(record.canvas_id.as_deref(), Some("canvas-7"));
    }

    #[test]
    fn record_without_sink_is_a_noop() {
        // No sink installed in this isolated assertion path: must not panic.
        record_policy_decision(RecordedPolicyDecision::new(
            1,
            sample_input(),
            allow_decision(),
            vec![],
            "test",
        ));
    }

    #[test]
    fn installing_a_sink_makes_dispatch_live_and_panic_free() {
        // The OnceLock is process-global and first-writer-wins, so a collector
        // assertion would race other installers in the same test binary. Assert
        // only the race-free invariants: after install the seam is live, and
        // dispatching through it never blocks or panics. End-to-end persistence
        // is covered by the daemon recording integration test.
        static OBSERVED: Mutex<bool> = Mutex::new(false);
        install_decision_sink(Box::new(|_decision| {
            *OBSERVED.lock().expect("observed lock") = true;
        }));
        assert!(
            DECISION_SINK.get().is_some(),
            "a sink must be installed after install_decision_sink"
        );
        record_policy_decision(RecordedPolicyDecision::new(
            3,
            sample_input(),
            deny_decision(),
            vec!["node-1".to_owned()],
            "unit",
        ));
    }
}
