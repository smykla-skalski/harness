use super::{
    TaskBoardTriageEffectiveSource, TaskBoardTriageOverride, effective_triage_outcome,
    is_canonical_override_actor, is_canonical_override_reason, suppress_placement_for_override,
};
use crate::task_board::{TaskBoardTriageDecision, TriageCause, TriageReasonCode, TriageVerdict};

fn decision(verdict: TriageVerdict) -> TaskBoardTriageDecision {
    TaskBoardTriageDecision {
        verdict,
        reason_code: TriageReasonCode::MeaningfulLabel,
        reason_detail: None,
        evaluator_identity: "task_board.triage.builtin_v1".to_string(),
        evaluator_version: 1,
        evidence_fingerprint: "sha256:".to_string() + &"0".repeat(64),
        cause: TriageCause::Initial,
        decided_at: "2026-07-23T00:00:00Z".to_string(),
    }
}

fn override_(verdict: TriageVerdict) -> TaskBoardTriageOverride {
    TaskBoardTriageOverride {
        verdict,
        actor: "operator-1".to_string(),
        reason: None,
        set_at: "2026-07-23T00:00:00Z".to_string(),
    }
}

#[test]
fn effective_outcome_prefers_an_active_override_over_the_automatic_decision() {
    let outcome = effective_triage_outcome(
        Some(&override_(TriageVerdict::Undecided)),
        Some(&decision(TriageVerdict::Todo)),
    )
    .expect("effective outcome");
    assert_eq!(outcome.verdict, TriageVerdict::Undecided);
    assert_eq!(outcome.source, TaskBoardTriageEffectiveSource::Override);
}

#[test]
fn effective_outcome_falls_back_to_the_automatic_decision_without_an_override() {
    let outcome = effective_triage_outcome(None, Some(&decision(TriageVerdict::Todo)))
        .expect("effective outcome");
    assert_eq!(outcome.verdict, TriageVerdict::Todo);
    assert_eq!(outcome.source, TaskBoardTriageEffectiveSource::Automatic);
}

#[test]
fn effective_outcome_is_none_without_either_side() {
    assert!(effective_triage_outcome(None, None).is_none());
}

#[test]
fn placement_is_suppressed_only_while_an_override_is_active() {
    assert!(suppress_placement_for_override(Some(&override_(
        TriageVerdict::Todo
    ))));
    assert!(!suppress_placement_for_override(None));
}

#[test]
fn actor_and_reason_validators_reject_blank_control_and_oversized_text() {
    assert!(is_canonical_override_actor("operator-1"));
    assert!(!is_canonical_override_actor(""));
    assert!(!is_canonical_override_actor("   "));
    assert!(!is_canonical_override_actor("bad\u{0007}actor"));
    assert!(!is_canonical_override_actor(&"a".repeat(257)));

    assert!(is_canonical_override_reason("looks fine"));
    assert!(!is_canonical_override_reason(""));
    assert!(!is_canonical_override_reason(&"a".repeat(257)));
}
