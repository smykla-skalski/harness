use super::*;

#[test]
fn switching_active_canvas_changes_compatibility_pipeline_target() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let original_id = workspace.active_canvas_id.clone();
    let duplicate = store
        .duplicate_canvas(&original_id, Some("Experiment A".to_string()))
        .expect("duplicate canvas");
    let mut edited_document = duplicate.document.clone();
    edited_document.policy_trace_ids = vec!["experiment-a".to_string()];

    let updated_workspace = store
        .set_active_canvas(&duplicate.id)
        .expect("activate duplicate canvas");
    assert_eq!(updated_workspace.active_canvas_id, duplicate.id);

    let saved = store
        .save_draft(edited_document.clone(), duplicate.document.revision)
        .expect("save active duplicate");
    assert!(saved.persisted, "active duplicate draft should persist");
    assert_eq!(
        store.load_or_seed().expect("load active duplicate"),
        saved.document,
        "compatibility getter should follow the active canvas",
    );

    let restored_workspace = store
        .set_active_canvas(&original_id)
        .expect("restore original active canvas");
    assert_eq!(restored_workspace.active_canvas_id, original_id);
    assert_ne!(
        store.load_or_seed().expect("load restored original"),
        saved.document,
        "switching active canvas should restore the original compatibility target",
    );
}

#[test]
fn create_canvas_adds_new_seeded_draft_and_makes_it_active() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let initial_workspace = store.load_workspace_or_seed().expect("seed workspace");

    let created = store
        .create_canvas(Some("Net new".to_string()))
        .expect("create canvas");

    let workspace = store.load_workspace_or_seed().expect("reload workspace");
    assert_eq!(
        workspace.canvases.len(),
        initial_workspace.canvases.len() + 1
    );
    assert_eq!(workspace.active_canvas_id, created.id);

    let active = active_canvas(&workspace);
    assert_eq!(active.title, "Net new");
    assert_eq!(active.document.mode, PolicyGraphMode::Draft);
    assert!(
        active.document.validate().is_valid(),
        "new canvas should start valid"
    );
    assert_eq!(
        store.load_or_seed().expect("compatibility load"),
        active.document,
        "compatibility getter should point at the new active canvas",
    );
}

#[test]
fn delete_canvas_rejects_removing_the_last_canvas() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let inactive_canvas_id = workspace
        .canvases
        .iter()
        .find(|canvas| canvas.id != workspace.active_canvas_id)
        .expect("seeded workspace has an inactive canvas")
        .id
        .clone();
    store
        .delete_canvas(&inactive_canvas_id)
        .expect("delete inactive canvas");
    let workspace = store
        .load_workspace_or_seed()
        .expect("reload single-canvas workspace");

    let error = store
        .delete_canvas(&workspace.active_canvas_id)
        .expect_err("last canvas deletion must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("last canvas"),
        "unexpected error detail: {detail}",
    );
}

#[test]
fn rename_canvas_updates_title_without_replacing_active_document() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let baseline_document = store.load_or_seed().expect("load active canvas");

    let renamed_workspace = store
        .rename_canvas(&workspace.active_canvas_id, "Policies v2")
        .expect("rename active canvas");

    assert_eq!(active_canvas(&renamed_workspace).title, "Policies v2");
    assert_eq!(
        store.load_or_seed().expect("reload active document"),
        baseline_document,
        "renaming should not replace the active document",
    );
}

#[test]
fn save_draft_for_active_canvas_rejects_canvas_selection_conflict() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let original_id = workspace.active_canvas_id.clone();
    let duplicate = store
        .duplicate_canvas(&original_id, Some("Experiment".to_string()))
        .expect("duplicate canvas");
    store
        .set_active_canvas(&duplicate.id)
        .expect("activate duplicate canvas");

    let error = store
        .save_draft_for_active_canvas(
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
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let original_id = workspace.active_canvas_id.clone();
    let duplicate = store
        .duplicate_canvas(&original_id, Some("Experiment".to_string()))
        .expect("duplicate canvas");
    store
        .set_active_canvas(&duplicate.id)
        .expect("activate duplicate canvas");

    let error = store
        .promote(&PolicyPipelinePromoteRequest {
            revision: duplicate.document.revision,
            actor: None,
            canvas_id: Some(original_id),
        })
        .expect_err("stale canvas selection must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("canvas selection changed"),
        "unexpected error detail: {detail}",
    );
}
