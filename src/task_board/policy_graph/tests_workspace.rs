use super::*;
#[test]
fn switching_active_canvas_changes_active_policy_document() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let original_id = ws.active_canvas_id.clone();
    let duplicate = apply_duplicate(&mut ws, &original_id, Some("Experiment A".to_string()))
        .expect("duplicate canvas");
    let mut edited_document = duplicate.document.clone();
    edited_document.policy_trace_ids = vec!["experiment-a".to_string()];

    apply_set_active(&mut ws, &duplicate.id).expect("activate duplicate canvas");
    assert_eq!(ws.active_canvas_id, duplicate.id);

    let saved = apply_save_draft(
        &mut ws,
        edited_document.clone(),
        duplicate.document.revision,
        None,
    )
    .expect("save active duplicate");
    assert!(saved.persisted, "active duplicate draft should persist");
    assert_eq!(
        ws.active_canvas().expect("active canvas").document,
        saved.document,
        "active canvas document should match the saved document",
    );

    apply_set_active(&mut ws, &original_id).expect("restore original active canvas");
    assert_eq!(ws.active_canvas_id, original_id);
    assert_ne!(
        ws.active_canvas().expect("active canvas").document,
        saved.document,
        "switching active canvas should restore the original document",
    );
}

#[test]
fn create_canvas_adds_new_seeded_draft_and_makes_it_active() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let initial_len = ws.canvases.len();

    let created = apply_create(&mut ws, Some("Net new".to_string())).expect("create canvas");

    assert_eq!(ws.canvases.len(), initial_len + 1);
    assert_eq!(ws.active_canvas_id, created.id);

    let active = active_canvas(&ws);
    assert_eq!(active.title, "Net new");
    assert_eq!(active.document.mode, PolicyGraphMode::Draft);
    assert!(
        active.document.validate().is_valid(),
        "new canvas should start valid"
    );
    assert_eq!(
        active.document,
        ws.active_canvas().expect("active canvas").document,
        "active canvas should be the newly created canvas",
    );
}

#[test]
fn delete_canvas_rejects_removing_the_last_canvas() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    while ws.canvases.len() > 1 {
        let inactive_canvas_id = ws
            .canvases
            .iter()
            .find(|canvas| canvas.id != ws.active_canvas_id)
            .expect("seeded workspace has an inactive canvas")
            .id
            .clone();
        apply_delete(&mut ws, &inactive_canvas_id).expect("delete inactive canvas");
    }

    let last_canvas_id = ws.active_canvas_id.clone();
    let error =
        apply_delete(&mut ws, &last_canvas_id).expect_err("last canvas deletion must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("last canvas"),
        "unexpected error detail: {detail}",
    );
}

#[test]
fn deleting_review_screenshot_canvas_respects_tombstone() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let review_screenshot_id = review_screenshot_canvas(&ws).id.clone();

    apply_delete(&mut ws, &review_screenshot_id).expect("delete");
    assert!(ws.canvases.iter().all(|c| c.id != review_screenshot_id));

    let reseeded = ws.ensure_review_screenshot_extraction_canvas();
    assert!(
        !reseeded,
        "tombstone must prevent re-seeding deleted canvas"
    );
    assert!(ws.canvases.iter().all(|c| c.id != review_screenshot_id));
}

#[test]
fn deleting_manual_ocr_paste_canvas_respects_tombstone() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let manual_ocr_id = manual_ocr_paste_canvas(&ws).id.clone();

    apply_delete(&mut ws, &manual_ocr_id).expect("delete");
    assert!(ws.canvases.iter().all(|c| c.id != manual_ocr_id));

    let reseeded = ws.ensure_manual_ocr_paste_canvas();
    assert!(
        !reseeded,
        "tombstone must prevent re-seeding deleted canvas"
    );
    assert!(ws.canvases.iter().all(|c| c.id != manual_ocr_id));
}

#[test]
fn ensure_seeded_automation_canvases_adds_missing_screenshot_canvas() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let review_screenshot_id = review_screenshot_canvas(&ws).id.clone();
    ws.canvases
        .retain(|canvas| canvas.id != review_screenshot_id);

    let repaired = ws.ensure_seeded_automation_canvases();

    assert!(repaired);
    assert!(
        ws.canvases
            .iter()
            .any(|canvas| canvas.is_review_screenshot_extraction_canvas)
    );
}

#[test]
fn ensure_screenshot_canvas_preserves_noncanonical_legacy_custom_graph() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let canvas = ws
        .canvases
        .iter_mut()
        .find(|canvas| canvas.is_review_screenshot_extraction_canvas)
        .expect("review screenshot canvas");
    canvas.document.policy_trace_ids = vec!["review-screenshot-extraction-canvas-v2".to_string()];
    canvas.document.nodes.push(PolicyGraphNode {
        id: "custom-review-screenshot-note".into(),
        label: "Custom note".to_string(),
        kind: PolicyGraphNodeKind::Hub,
        automation: None,
        input_ports: vec![PORT_IN.into()],
        output_ports: vec!["out_1".into()],
        group_id: None,
    });
    let before = canvas.document.clone();

    let repaired = ws.ensure_review_screenshot_extraction_canvas();

    assert!(!repaired, "custom legacy graph should be preserved");
    assert_eq!(review_screenshot_canvas(&ws).document, before);
}

#[test]
fn ensure_seeded_automation_canvases_adds_missing_manual_ocr_canvas() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let manual_ocr_id = manual_ocr_paste_canvas(&ws).id.clone();
    ws.canvases.retain(|canvas| canvas.id != manual_ocr_id);

    let repaired = ws.ensure_seeded_automation_canvases();

    assert!(repaired);
    assert!(
        ws.canvases
            .iter()
            .any(|canvas| canvas.is_manual_ocr_paste_canvas)
    );
}

#[test]
fn text_paste_ensure_does_not_seed_screenshot_canvas() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let review_screenshot_id = review_screenshot_canvas(&ws).id.clone();
    ws.canvases
        .retain(|canvas| canvas.id != review_screenshot_id);

    let repaired = ws.ensure_review_text_paste_dry_run_canvas();

    assert!(!repaired);
    assert!(
        ws.canvases
            .iter()
            .all(|canvas| !canvas.is_review_screenshot_extraction_canvas)
    );
}

#[test]
fn rename_canvas_updates_title_without_replacing_active_document() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let active_canvas_id = ws.active_canvas_id.clone();
    let baseline_document = ws.active_canvas().expect("active canvas").document.clone();

    apply_rename(&mut ws, &active_canvas_id, "Policies v2").expect("rename active canvas");

    assert_eq!(active_canvas(&ws).title, "Policies v2");
    assert_eq!(
        ws.active_canvas().expect("active canvas").document,
        baseline_document,
        "renaming should not replace the active document",
    );
}

#[test]
fn set_global_enforcement_flips_global_gate_without_mutating_canvases() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    ws.canvases[0].document.mode = PolicyGraphMode::Enforced;
    ws.canvases[1].document.mode = PolicyGraphMode::DryRun;
    let before = ws.clone();

    let enabled = apply_set_global_enforcement(&mut ws, false);

    assert!(!enabled);
    assert!(!ws.global_policy_enforcement_enabled);
    assert_eq!(ws.active_canvas_id, before.active_canvas_id);
    assert_eq!(ws.canvases, before.canvases);
    assert!(ws.active_enforced_canvas().is_none());

    let enabled = apply_set_global_enforcement(&mut ws, true);

    assert!(enabled);
    assert_eq!(ws, before);
}

#[test]
fn rename_review_text_paste_canvas_persists_without_reseeding_duplicate() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let review_text_paste_id = review_text_paste_canvas(&ws).id.clone();

    apply_rename(&mut ws, &review_text_paste_id, "Pasted PR approvals").expect("rename");

    // Simulate what would happen on reload: ensure_review_text_paste_dry_run_canvas
    // must not seed a second dry-run canvas when the original is still present
    // (just renamed); is_review_text_paste_dry_run_canvas guards this.
    ws.ensure_review_text_paste_dry_run_canvas();

    assert_eq!(
        ws.canvases.len(),
        PolicyCanvasWorkspace::seeded().canvases.len()
    );
    assert!(
        ws.canvases
            .iter()
            .any(|c| c.id == review_text_paste_id && c.title == "Pasted PR approvals")
    );
    assert_eq!(
        ws.canvases
            .iter()
            .filter(|c| c.title == "Pasted PR approvals (dry run)")
            .count(),
        0
    );
}

#[test]
fn deleting_review_text_paste_canvas_respects_tombstone() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let review_text_paste_id = review_text_paste_canvas(&ws).id.clone();

    apply_delete(&mut ws, &review_text_paste_id).expect("delete");
    assert!(ws.canvases.iter().all(|c| c.id != review_text_paste_id));

    // Simulate what would happen on reload: ensure_review_text_paste_dry_run_canvas
    // must NOT re-seed the canvas because review_text_paste_dry_run_canvas_deleted
    // was set true by apply_delete.
    let reseeded = ws.ensure_review_text_paste_dry_run_canvas();
    assert!(
        !reseeded,
        "tombstone must prevent re-seeding deleted canvas"
    );
    assert!(ws.canvases.iter().all(|c| c.id != review_text_paste_id));
}

#[test]
fn save_draft_for_active_canvas_rejects_canvas_selection_conflict() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let original_id = ws.active_canvas_id.clone();
    let duplicate = apply_duplicate(&mut ws, &original_id, Some("Experiment".to_string()))
        .expect("duplicate canvas");
    apply_set_active(&mut ws, &duplicate.id).expect("activate duplicate canvas");

    let error = apply_save_draft(
        &mut ws,
        duplicate.document.clone(),
        duplicate.document.revision,
        Some(&original_id),
    )
    .expect_err("stale canvas selection must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("canvas selection changed"),
        "unexpected error detail: {detail}",
    );
}

#[test]
fn promote_rejects_canvas_selection_conflict() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let original_id = ws.active_canvas_id.clone();
    let duplicate = apply_duplicate(&mut ws, &original_id, Some("Experiment".to_string()))
        .expect("duplicate canvas");
    apply_set_active(&mut ws, &duplicate.id).expect("activate duplicate canvas");

    let error = apply_promote(
        &mut ws,
        &PolicyPipelinePromoteRequest {
            revision: duplicate.document.revision,
            actor: None,
            canvas_id: Some(original_id),
        },
    )
    .expect_err("stale canvas selection must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("canvas selection changed"),
        "unexpected error detail: {detail}",
    );
}

fn review_text_paste_canvas(workspace: &PolicyCanvasWorkspace) -> &PolicyCanvasRecord {
    workspace
        .canvases
        .iter()
        .find(|canvas| canvas.is_review_text_paste_dry_run_canvas)
        .expect("review text paste canvas")
}

fn manual_ocr_paste_canvas(workspace: &PolicyCanvasWorkspace) -> &PolicyCanvasRecord {
    workspace
        .canvases
        .iter()
        .find(|canvas| canvas.is_manual_ocr_paste_canvas)
        .expect("manual OCR paste canvas")
}

fn review_screenshot_canvas(workspace: &PolicyCanvasWorkspace) -> &PolicyCanvasRecord {
    workspace
        .canvases
        .iter()
        .find(|canvas| canvas.is_review_screenshot_extraction_canvas)
        .expect("review screenshot extraction canvas")
}

#[test]
fn import_canvas_validates_and_creates_new_canvas() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let initial_len = ws.canvases.len();
    let doc = PolicyGraph::seeded_v2();

    let imported = apply_import(&mut ws, doc.clone(), Some("Imported".to_string()))
        .expect("import valid graph");

    assert_eq!(ws.canvases.len(), initial_len + 1);
    assert_eq!(imported.title, "Imported");
    assert_eq!(imported.document.mode, PolicyGraphMode::Draft);
    assert_eq!(
        ws.active_canvas_id, imported.id,
        "import sets the canvas active"
    );
}

#[test]
fn import_canvas_rejects_invalid_graph() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let initial_len = ws.canvases.len();
    let mut invalid = PolicyGraph::seeded_v2();
    invalid.edges.push(PolicyGraphEdge {
        id: "edge:dangling".into(),
        from_node: "no-such-node".into(),
        from_port: "out".into(),
        to_node: "no-such-node".into(),
        to_port: PORT_IN.into(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });

    let error =
        apply_import(&mut ws, invalid, None).expect_err("import invalid graph must be rejected");
    assert_eq!(
        ws.canvases.len(),
        initial_len,
        "workspace must be unchanged after rejection"
    );
    assert!(
        error.to_string().contains("validation failed"),
        "unexpected error: {error}",
    );
}

#[test]
fn import_canvas_uses_default_title_when_none_given() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let doc = PolicyGraph::seeded_v2();

    let imported = apply_import(&mut ws, doc, None).expect("import without title");

    assert!(
        !imported.title.is_empty(),
        "default title must not be empty"
    );
}
