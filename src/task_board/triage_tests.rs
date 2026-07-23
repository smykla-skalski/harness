use super::*;
use crate::task_board::types::{ExternalRef, TaskBoardItemKind};

fn item() -> TaskBoardItem {
    TaskBoardItem::new(
        "item-1".into(),
        "Title".into(),
        "Body".into(),
        "2026-07-22T00:00:00Z".into(),
    )
}

#[test]
fn canonicalize_labels_trims_lowercases_dedupes_and_sorts() {
    let tags = vec![
        " Kind/Bug ".to_string(),
        "kind/bug".to_string(),
        "Area/API".to_string(),
        String::new(),
        "  ".to_string(),
    ];
    assert_eq!(
        canonicalize_labels(&tags),
        vec!["area/api".to_string(), "kind/bug".to_string()]
    );
}

#[test]
fn exclusion_labels_cover_bare_and_triage_prefixed_forms_case_insensitively() {
    for label in [
        "duplicate",
        "invalid",
        "wontfix",
        "triage/duplicate",
        "triage/invalid",
        "triage/wontfix",
    ] {
        assert!(is_exclusion_label(label), "{label} should be an exclusion");
        let matched = matched_exclusion_label(&[format!(" {}", label.to_uppercase())]);
        assert_eq!(matched, Some(label.to_string()));
    }
    assert!(!is_exclusion_label("triage/needs-info"));
    assert!(!is_exclusion_label("kind/bug"));
    assert_eq!(matched_exclusion_label(&["kind/bug".to_string()]), None);
}

#[test]
fn needs_info_label_yields_undecided_even_with_other_labels_present() {
    let mut with_needs_info = item();
    with_needs_info.tags = vec!["kind/bug".to_string(), "triage/needs-info".to_string()];
    let outcome = evaluate_builtin_v1(&with_needs_info);
    assert_eq!(outcome.verdict, TriageVerdict::Undecided);
    assert_eq!(outcome.reason_code, TriageReasonCode::NeedsInfoLabel);
    assert_eq!(outcome.reason_detail.as_deref(), Some("triage/needs-info"));
}

#[test]
fn zero_meaningful_labels_yields_undecided() {
    let bare = item();
    let outcome = evaluate_builtin_v1(&bare);
    assert_eq!(outcome.verdict, TriageVerdict::Undecided);
    assert_eq!(outcome.reason_code, TriageReasonCode::NoMeaningfulLabels);
    assert_eq!(outcome.reason_detail, None);
}

#[test]
fn any_remaining_label_yields_todo_not_only_priority_labels() {
    for label in ["kind/bug", "area/api", "help wanted", "priority/low"] {
        let mut tagged = item();
        tagged.tags = vec![label.to_string()];
        let outcome = evaluate_builtin_v1(&tagged);
        assert_eq!(
            outcome.verdict,
            TriageVerdict::Todo,
            "label {label} should promote to Todo"
        );
        assert_eq!(outcome.reason_code, TriageReasonCode::MeaningfulLabel);
    }
}

#[test]
fn evidence_fingerprint_is_deterministic_for_identical_evidence() {
    let a = item();
    let b = item();
    assert_eq!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_ignores_label_order_and_case() {
    let mut a = item();
    a.tags = vec!["Kind/Bug".to_string(), "Area/API".to_string()];
    let mut b = item();
    b.tags = vec!["area/api".to_string(), "kind/bug".to_string()];
    assert_eq!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_ignores_duplicate_labels() {
    let mut a = item();
    a.tags = vec!["kind/bug".to_string()];
    let mut b = item();
    b.tags = vec!["kind/bug".to_string(), "kind/bug".to_string()];
    assert_eq!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_changes_when_title_changes() {
    let a = item();
    let mut b = item();
    b.title = "Different title".into();
    assert_ne!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_changes_when_body_changes() {
    let a = item();
    let mut b = item();
    b.body = "Different body".into();
    assert_ne!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_changes_when_priority_changes() {
    let a = item();
    let mut b = item();
    b.priority = TaskBoardPriority::Critical;
    assert_ne!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_changes_when_labels_change() {
    let a = item();
    let mut b = item();
    b.tags = vec!["kind/bug".to_string()];
    assert_ne!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_changes_when_kind_changes() {
    let a = item();
    let mut b = item();
    b.kind = TaskBoardItemKind::Umbrella;
    assert_ne!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_changes_when_external_refs_change() {
    let a = item();
    let mut b = item();
    b.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: None,
    }];
    assert_ne!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_ignores_volatile_and_lane_fields() {
    let a = item();
    let mut b = item();
    b.updated_at = "2026-07-22T12:00:00Z".into();
    b.session_id = Some("session-1".into());
    b.work_item_id = Some("work-1".into());
    b.usage.input_tokens = Some(42);
    b.lane_position = Some(3);
    b.lane_origin = Some(super::super::lane::TaskBoardLaneOrigin::Manual {
        actor: "person".into(),
    });
    b.lane_set_at = Some("2026-07-22T12:00:00Z".into());
    assert_eq!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn evidence_fingerprint_ignores_planning_approval() {
    let a = item();
    let mut b = item();
    b.planning.summary = Some("A plan".into());
    b.planning.approved_by = Some("person".into());
    b.planning.approved_at = Some("2026-07-22T12:00:00Z".into());
    assert_eq!(evidence_fingerprint(&a), evidence_fingerprint(&b));
}

#[test]
fn canonical_evidence_fingerprint_validator_accepts_only_the_produced_shape() {
    let fingerprint = evidence_fingerprint(&item());
    assert!(is_canonical_evidence_fingerprint(&fingerprint));
    assert!(!is_canonical_evidence_fingerprint("sha256:short"));
    assert!(!is_canonical_evidence_fingerprint(
        &fingerprint.to_uppercase()
    ));
    assert!(!is_canonical_evidence_fingerprint("not-a-fingerprint"));
}

#[test]
fn canonical_bounded_text_rejects_blank_oversized_and_control_characters() {
    assert!(is_canonical_evaluator_identity(
        BUILTIN_V1_EVALUATOR_IDENTITY
    ));
    assert!(!is_canonical_evaluator_identity(""));
    assert!(!is_canonical_evaluator_identity("   "));
    assert!(!is_canonical_evaluator_identity(&"x".repeat(257)));
    assert!(!is_canonical_evaluator_identity("bad\u{0007}value"));
    assert!(is_canonical_reason_detail("triage/needs-info"));
    assert!(!is_canonical_reason_detail(&"x".repeat(257)));
}
