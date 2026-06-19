use super::*;

#[test]
fn make_live_promotes_active_canvas_and_enables_global_enforcement() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    // Start from a non-live baseline so the flip is observable.
    apply_set_global_enforcement(&mut ws, false);
    let document = ws.active_canvas().expect("active canvas").document.clone();
    let saved = apply_save_draft(&mut ws, document, 0, None).expect("save draft");
    assert!(saved.persisted);

    let response = apply_make_live(
        &mut ws,
        &PolicyPipelineMakeLiveRequest {
            revision: saved.document.revision,
            actor: None,
            canvas_id: None,
        },
    )
    .expect("make live");

    assert_eq!(response.document.mode, PolicyGraphMode::Enforced);
    assert_eq!(response.document.revision, saved.document.revision);
    assert!(response.global_policy_enforcement_enabled);
    assert!(ws.global_policy_enforcement_enabled);
    let live = ws.active_enforced_canvas().expect("active enforced canvas");
    assert_eq!(live.document.mode, PolicyGraphMode::Enforced);
    assert_eq!(live.document.revision, saved.document.revision);
}

#[test]
fn make_live_rejects_a_stale_revision_without_enabling_enforcement() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    apply_set_global_enforcement(&mut ws, false);
    let revision = ws.active_canvas().expect("active canvas").document.revision;

    let result = apply_make_live(
        &mut ws,
        &PolicyPipelineMakeLiveRequest {
            revision: revision + 1,
            actor: None,
            canvas_id: None,
        },
    );

    assert!(result.is_err());
    assert!(
        !ws.global_policy_enforcement_enabled,
        "a rejected make-live must not flip global enforcement on",
    );
}

#[test]
fn go_live_diff_reports_parity_when_no_policy_is_live() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    apply_set_global_enforcement(&mut ws, false);

    let diff = apply_diff_against_live(&ws, None, None).expect("diff against live");

    assert!(!diff.has_live_policy);
    assert_eq!(diff.changed_count, 0);
    assert_eq!(diff.diffs.len(), ws.scenarios.len());
    assert!(diff.diffs.iter().all(|entry| entry.live_decision.is_none()));
    assert!(diff.diffs.iter().all(|entry| !entry.changed));
}

#[test]
fn go_live_diff_reports_parity_when_candidate_matches_live() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let revision = ws.active_canvas().expect("active canvas").document.revision;
    apply_make_live(
        &mut ws,
        &PolicyPipelineMakeLiveRequest {
            revision,
            actor: None,
            canvas_id: None,
        },
    )
    .expect("make live");
    let live_document = ws
        .active_enforced_canvas()
        .expect("active enforced canvas")
        .document
        .clone();

    let diff = apply_diff_against_live(&ws, Some(live_document), None).expect("diff against live");

    assert!(diff.has_live_policy);
    assert_eq!(diff.changed_count, 0);
    assert_eq!(diff.diffs.len(), ws.scenarios.len());
    assert!(
        diff.diffs
            .iter()
            .all(|entry| entry.live_decision.as_ref() == Some(&entry.draft_decision)),
        "an identical candidate must agree with the live policy on every scenario",
    );
}

#[test]
fn go_live_diff_flags_a_changed_decision_against_live() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let revision = ws.active_canvas().expect("active canvas").document.revision;
    apply_make_live(
        &mut ws,
        &PolicyPipelineMakeLiveRequest {
            revision,
            actor: None,
            canvas_id: None,
        },
    )
    .expect("make live");

    // Tighten the candidate's risk gate so the green merge scenario, which the
    // live policy auto-allows at the default threshold, no longer clears it.
    let mut candidate = ws
        .active_enforced_canvas()
        .expect("active enforced canvas")
        .document
        .clone();
    for node in &mut candidate.nodes {
        if let PolicyGraphNodeKind::RiskClassifier { threshold, .. } = &mut node.kind {
            *threshold = 0;
        }
    }

    let diff = apply_diff_against_live(&ws, Some(candidate), None).expect("diff against live");

    assert!(diff.has_live_policy);
    assert!(
        diff.changed_count >= 1,
        "tightening the risk gate must change at least one decision",
    );
    let merge = diff
        .diffs
        .iter()
        .find(|entry| entry.action == PolicyAction::MergePr)
        .expect("merge scenario present");
    assert!(
        merge.changed,
        "the merge decision must be flagged as changed"
    );
    assert_ne!(merge.live_decision.as_ref(), Some(&merge.draft_decision));
}
