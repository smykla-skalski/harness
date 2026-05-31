use super::*;
#[test]
fn switching_active_canvas_changes_active_policy_document() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let original_id = ws.active_canvas_id.clone();
    let duplicate =
        apply_duplicate(&mut ws, &original_id, Some("Experiment A".to_string())).expect("duplicate canvas");
    let mut edited_document = duplicate.document.clone();
    edited_document.policy_trace_ids = vec!["experiment-a".to_string()];

    apply_set_active(&mut ws, &duplicate.id).expect("activate duplicate canvas");
    assert_eq!(ws.active_canvas_id, duplicate.id);

    let saved = apply_save_draft(&mut ws, edited_document.clone(), duplicate.document.revision, None)
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
    let inactive_canvas_id = ws
        .canvases
        .iter()
        .find(|canvas| canvas.id != ws.active_canvas_id)
        .expect("seeded workspace has an inactive canvas")
        .id
        .clone();
    apply_delete(&mut ws, &inactive_canvas_id).expect("delete inactive canvas");

    let last_canvas_id = ws.active_canvas_id.clone();
    let error = apply_delete(&mut ws, &last_canvas_id)
        .expect_err("last canvas deletion must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("last canvas"),
        "unexpected error detail: {detail}",
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
fn rename_review_text_paste_canvas_persists_without_reseeding_duplicate() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let review_text_paste_id = review_text_paste_canvas(&workspace).id.clone();

    store
        .rename_canvas(&review_text_paste_id, "Pasted PR approvals")
        .expect("rename review text paste canvas");

    let reloaded = store.load_workspace_or_seed().expect("reload renamed workspace");
    assert_eq!(reloaded.canvases.len(), workspace.canvases.len());
    assert!(
        reloaded
            .canvases
            .iter()
            .any(|canvas| canvas.id == review_text_paste_id && canvas.title == "Pasted PR approvals")
    );
    assert_eq!(
        reloaded
            .canvases
            .iter()
            .filter(|canvas| canvas.title == "Pasted PR approvals (dry run)")
            .count(),
        0
    );
}

#[test]
fn deleting_review_text_paste_canvas_persists_across_restart() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let review_text_paste_id = review_text_paste_canvas(&workspace).id.clone();

    let updated = store
        .delete_canvas(&review_text_paste_id)
        .expect("delete review text paste canvas");
    assert!(
        updated
            .canvases
            .iter()
            .all(|canvas| canvas.id != review_text_paste_id)
    );

    let reloaded = store
        .load_workspace_or_seed()
        .expect("reload workspace after deleting review text paste canvas");
    assert!(
        reloaded
            .canvases
            .iter()
            .all(|canvas| canvas.id != review_text_paste_id)
    );
    assert_eq!(reloaded.canvases.len(), updated.canvases.len());
}

#[test]
fn save_draft_for_active_canvas_rejects_canvas_selection_conflict() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let original_id = ws.active_canvas_id.clone();
    let duplicate =
        apply_duplicate(&mut ws, &original_id, Some("Experiment".to_string())).expect("duplicate canvas");
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
    let duplicate =
        apply_duplicate(&mut ws, &original_id, Some("Experiment".to_string())).expect("duplicate canvas");
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
