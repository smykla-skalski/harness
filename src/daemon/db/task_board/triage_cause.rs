use crate::task_board::{TaskBoardTriageDecision, TriageCause};

/// Whatever `triage_cause` needs to compare against a candidate evaluator
/// and evidence fingerprint. Implemented once by the full decision type
/// most callers already have in hand, and once by the lighter bulk-loaded
/// summary a reevaluation pass carries per item without a second per-item
/// read (see `triage_rules_bulk_load::CurrentDecisionInfo`).
pub(super) trait DecidedEvaluatorFingerprint {
    fn evaluator_identity(&self) -> &str;
    fn evaluator_version(&self) -> u32;
    fn evidence_fingerprint(&self) -> &str;
}

impl DecidedEvaluatorFingerprint for TaskBoardTriageDecision {
    fn evaluator_identity(&self) -> &str {
        &self.evaluator_identity
    }

    fn evaluator_version(&self) -> u32 {
        self.evaluator_version
    }

    fn evidence_fingerprint(&self) -> &str {
        &self.evidence_fingerprint
    }
}

/// An evaluator upgrade takes precedence over a simultaneous fingerprint
/// change: if both differ from the existing decision at once, the cause
/// reported is `ActiveEvaluatorChanged`, not `FingerprintChanged`, since the
/// evaluator identity/version change is the more significant reason a new
/// decision is warranted.
pub(super) fn triage_cause<T: DecidedEvaluatorFingerprint>(
    existing: Option<&T>,
    fingerprint: &str,
    active_evaluator_identity: &str,
    active_evaluator_version: u32,
) -> Option<TriageCause> {
    match existing {
        None => Some(TriageCause::Initial),
        Some(existing)
            if existing.evaluator_identity() != active_evaluator_identity
                || existing.evaluator_version() != active_evaluator_version =>
        {
            Some(TriageCause::ActiveEvaluatorChanged)
        }
        Some(existing) if existing.evidence_fingerprint() != fingerprint => {
            Some(TriageCause::FingerprintChanged)
        }
        Some(_) => None,
    }
}
