use tempfile::{TempDir, tempdir};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    POLICY_TRANSFER_FORMAT, POLICY_TRANSFER_VERSION, PolicyTransferBundle,
    PolicyTransferDumpRequest, PolicyTransferImportRequest, PolicyTransferWorkspaceMetadata,
};
use crate::task_board::policy_graph::{
    PolicyCanvasRecord, PolicyCanvasWorkspace, PolicyGraphMode, apply_rename, apply_scenario_create,
};

use super::{dump_policies, import_policies};

async fn connect() -> (TempDir, AsyncDaemonDb) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("connect async daemon db");
    (dir, db)
}

fn metadata(workspace: &PolicyCanvasWorkspace) -> PolicyTransferWorkspaceMetadata {
    PolicyTransferWorkspaceMetadata {
        schema_version: workspace.schema_version,
        active_canvas_id: workspace.active_canvas_id.clone(),
        global_policy_enforcement_enabled: workspace.global_policy_enforcement_enabled,
        manual_ocr_paste_canvas_deleted: workspace.manual_ocr_paste_canvas_deleted,
        review_text_paste_dry_run_canvas_deleted: workspace
            .review_text_paste_dry_run_canvas_deleted,
        review_screenshot_extraction_canvas_deleted: workspace
            .review_screenshot_extraction_canvas_deleted,
        scenarios: workspace.scenarios.clone(),
        scenarios_seeded: workspace.scenarios_seeded,
        spawn_requires_live_policy: workspace.spawn_requires_live_policy,
        spawn_kill_switch: workspace.spawn_kill_switch,
    }
}

fn bundle(
    policies: Vec<PolicyCanvasRecord>,
    workspace: Option<PolicyTransferWorkspaceMetadata>,
) -> PolicyTransferBundle {
    PolicyTransferBundle {
        format: POLICY_TRANSFER_FORMAT.to_string(),
        version: POLICY_TRANSFER_VERSION,
        policies,
        workspace,
    }
}

fn distinct_policy(source: &PolicyCanvasRecord, id: &str) -> PolicyCanvasRecord {
    let mut policy = source.clone();
    policy.id = id.to_string();
    policy.title = format!("Transferred {id}");
    policy.created_at = "2026-01-02T03:04:05Z".to_string();
    policy.updated_at = "2026-02-03T04:05:06Z".to_string();
    policy.document.mode = PolicyGraphMode::Enforced;
    policy.live_document = Some(policy.document.clone());
    policy.live_updated_at = Some("2026-02-03T04:05:07Z".to_string());
    policy
}

#[tokio::test]
async fn dump_all_preserves_exact_policies_and_includes_metadata() {
    let (_dir, db) = connect().await;
    let mut source = PolicyCanvasWorkspace::seeded();
    source.global_policy_enforcement_enabled = false;
    source.manual_ocr_paste_canvas_deleted = true;
    source.scenarios_seeded = false;
    source.spawn_requires_live_policy = false;
    source.spawn_kill_switch = true;
    source.canvases[0] = distinct_policy(&source.canvases[0], "policy-exact");
    source.active_canvas_id = source.canvases[0].id.clone();
    db.replace_policy_workspace(&source)
        .await
        .expect("seed source workspace");
    let sequence_before = db.current_change_sequence().await.expect("sequence before");

    let dumped = dump_policies(&db, &PolicyTransferDumpRequest::default())
        .await
        .expect("dump all policies");

    assert_eq!(dumped.format, POLICY_TRANSFER_FORMAT);
    assert_eq!(dumped.version, POLICY_TRANSFER_VERSION);
    assert_eq!(dumped.policies, source.canvases);
    assert_eq!(dumped.workspace, Some(metadata(&source)));
    assert_eq!(
        db.load_policy_workspace()
            .await
            .expect("workspace after dump"),
        Some(source),
    );
    assert_eq!(
        db.current_change_sequence().await.expect("sequence after"),
        sequence_before,
    );
}

#[tokio::test]
async fn filtered_dump_uses_requested_order_and_omits_metadata() {
    let (_dir, db) = connect().await;
    let source = PolicyCanvasWorkspace::seeded();
    db.replace_policy_workspace(&source)
        .await
        .expect("seed source workspace");
    let ids = vec![source.canvases[2].id.clone(), source.canvases[0].id.clone()];

    let dumped = dump_policies(
        &db,
        &PolicyTransferDumpRequest {
            policy_ids: ids.clone(),
        },
    )
    .await
    .expect("dump selected policies");

    assert_eq!(
        dumped
            .policies
            .iter()
            .map(|policy| policy.id.clone())
            .collect::<Vec<_>>(),
        ids,
    );
    assert!(dumped.workspace.is_none());
}

#[tokio::test]
async fn merge_import_upserts_by_id_and_preserves_target_workspace_metadata() {
    let (_dir, db) = connect().await;
    let mut target = PolicyCanvasWorkspace::seeded();
    target.global_policy_enforcement_enabled = false;
    target.scenarios_seeded = false;
    target.spawn_kill_switch = true;
    let target_metadata = metadata(&target);
    let untouched = target.canvases[1].clone();
    let replacement = distinct_policy(&target.canvases[0], &target.canvases[0].id);
    let appended = distinct_policy(&target.canvases[0], "policy-appended");
    db.replace_policy_workspace(&target)
        .await
        .expect("seed target workspace");
    let sequence_before = db.current_change_sequence().await.expect("sequence before");
    let mut ignored_source_metadata = metadata(&target);
    ignored_source_metadata.global_policy_enforcement_enabled = true;
    ignored_source_metadata.spawn_kill_switch = false;

    import_policies(
        &db,
        &PolicyTransferImportRequest {
            bundle: bundle(
                vec![replacement.clone(), appended.clone()],
                Some(ignored_source_metadata),
            ),
            replace_all: false,
        },
    )
    .await
    .expect("merge policy bundle");

    let loaded = db
        .load_policy_workspace()
        .await
        .expect("load merged workspace")
        .expect("workspace exists");
    assert_eq!(metadata(&loaded), target_metadata);
    assert_eq!(loaded.canvas(&replacement.id), Some(&replacement));
    assert_eq!(loaded.canvas(&appended.id), Some(&appended));
    assert_eq!(loaded.canvas(&untouched.id), Some(&untouched));
    assert_eq!(
        db.current_change_sequence().await.expect("sequence after"),
        sequence_before + 1,
    );
    assert_eq!(
        db.load_change_tracking_since(sequence_before)
            .await
            .expect("change rows"),
        vec![(
            "task_board:policy_pipeline".to_string(),
            sequence_before + 1,
        )],
    );
}

#[tokio::test]
async fn replace_all_import_replaces_complete_workspace_exactly() {
    let (_dir, db) = connect().await;
    db.replace_policy_workspace(&PolicyCanvasWorkspace::seeded())
        .await
        .expect("seed target workspace");
    let mut source = PolicyCanvasWorkspace::seeded();
    source.canvases = vec![
        distinct_policy(&source.canvases[0], "policy-first"),
        distinct_policy(&source.canvases[1], "policy-second"),
    ];
    source.active_canvas_id = source.canvases[1].id.clone();
    source.global_policy_enforcement_enabled = false;
    source.manual_ocr_paste_canvas_deleted = true;
    source.review_text_paste_dry_run_canvas_deleted = true;
    source.review_screenshot_extraction_canvas_deleted = true;
    source.scenarios.clear();
    source.scenarios_seeded = false;
    source.spawn_requires_live_policy = false;
    source.spawn_kill_switch = true;

    import_policies(
        &db,
        &PolicyTransferImportRequest {
            bundle: bundle(source.canvases.clone(), Some(metadata(&source))),
            replace_all: true,
        },
    )
    .await
    .expect("replace policy workspace");

    assert_eq!(
        db.load_policy_workspace()
            .await
            .expect("load replaced workspace"),
        Some(source),
    );
}

#[tokio::test]
async fn dumped_reachable_workspace_reimports_exactly() {
    let (_dir, db) = connect().await;
    let mut source = PolicyCanvasWorkspace::seeded();
    let first_id = source.canvases[0].id.clone();
    let second_id = source.canvases[1].id.clone();
    apply_rename(&mut source, &first_id, "  padded title  ").expect("rename first policy");
    apply_rename(&mut source, &second_id, "").expect("rename second policy");
    let existing_scenario = source.scenarios[0].clone();
    apply_scenario_create(
        &mut source,
        &existing_scenario.name,
        existing_scenario.input,
    )
    .expect("create scenario with an existing name");
    db.replace_policy_workspace(&source)
        .await
        .expect("seed reachable source workspace");

    let dumped = dump_policies(&db, &PolicyTransferDumpRequest::default())
        .await
        .expect("dump reachable workspace");
    db.replace_policy_workspace(&PolicyCanvasWorkspace::seeded())
        .await
        .expect("replace source before import");
    import_policies(
        &db,
        &PolicyTransferImportRequest {
            bundle: dumped,
            replace_all: true,
        },
    )
    .await
    .expect("reimport reachable workspace");

    assert_eq!(
        db.load_policy_workspace()
            .await
            .expect("load reimported workspace"),
        Some(source),
    );
}

#[tokio::test]
async fn invalid_bundle_is_rejected_before_any_policy_is_written() {
    let (_dir, db) = connect().await;
    let target = PolicyCanvasWorkspace::seeded();
    db.replace_policy_workspace(&target)
        .await
        .expect("seed target workspace");
    let sequence_before = db.current_change_sequence().await.expect("sequence before");
    let valid = distinct_policy(&target.canvases[0], "policy-valid");
    let mut invalid = distinct_policy(&target.canvases[0], "policy-invalid");
    invalid.document.schema_version = u16::MAX;

    let error = import_policies(
        &db,
        &PolicyTransferImportRequest {
            bundle: bundle(vec![valid, invalid], None),
            replace_all: false,
        },
    )
    .await
    .expect_err("invalid graph must reject whole bundle");

    assert!(error.to_string().contains("policy-invalid"));
    assert_eq!(
        db.load_policy_workspace().await.expect("load after reject"),
        Some(target),
    );
    assert_eq!(
        db.current_change_sequence().await.expect("sequence after"),
        sequence_before,
    );
}

#[tokio::test]
async fn malformed_bundle_variants_are_rejected() {
    let (_dir, db) = connect().await;
    let source = PolicyCanvasWorkspace::seeded();
    let policy = source.canvases[0].clone();
    let mut unsupported_metadata = metadata(&source);
    unsupported_metadata.schema_version += 1;
    let cases = [
        PolicyTransferImportRequest {
            bundle: PolicyTransferBundle {
                format: "other-format".to_string(),
                ..bundle(vec![policy.clone()], None)
            },
            replace_all: false,
        },
        PolicyTransferImportRequest {
            bundle: PolicyTransferBundle {
                version: POLICY_TRANSFER_VERSION + 1,
                ..bundle(vec![policy.clone()], None)
            },
            replace_all: false,
        },
        PolicyTransferImportRequest {
            bundle: bundle(Vec::new(), None),
            replace_all: false,
        },
        PolicyTransferImportRequest {
            bundle: bundle(vec![policy.clone(), policy.clone()], None),
            replace_all: false,
        },
        PolicyTransferImportRequest {
            bundle: bundle(vec![policy.clone()], Some(unsupported_metadata)),
            replace_all: true,
        },
        PolicyTransferImportRequest {
            bundle: bundle(vec![policy], None),
            replace_all: true,
        },
    ];

    for request in cases {
        import_policies(&db, &request)
            .await
            .expect_err("malformed bundle must fail");
    }
    assert!(db.load_policy_workspace().await.expect("load").is_none());
    assert_eq!(db.current_change_sequence().await.expect("sequence"), 0);
}

#[tokio::test]
async fn dump_rejects_blank_selectors_without_mutating_workspace() {
    let (_dir, db) = connect().await;
    let source = PolicyCanvasWorkspace::seeded();
    db.replace_policy_workspace(&source)
        .await
        .expect("seed source workspace");
    let sequence_before = db.current_change_sequence().await.expect("sequence before");

    dump_policies(
        &db,
        &PolicyTransferDumpRequest {
            policy_ids: vec!["   ".to_string()],
        },
    )
    .await
    .expect_err("blank selector must fail");

    assert_eq!(
        db.load_policy_workspace()
            .await
            .expect("workspace after dump"),
        Some(source),
    );
    assert_eq!(
        db.current_change_sequence().await.expect("sequence after"),
        sequence_before,
    );
}

#[tokio::test]
async fn import_rejects_unpersistable_revisions_and_inconsistent_live_state() {
    let (_dir, db) = connect().await;
    let source = PolicyCanvasWorkspace::seeded();
    let mut oversized = distinct_policy(&source.canvases[0], "policy-oversized");
    oversized.document.revision = u64::try_from(i64::MAX).expect("i64 max fits u64") + 1;
    let mut draft_live = distinct_policy(&source.canvases[0], "policy-draft-live");
    draft_live
        .live_document
        .as_mut()
        .expect("live document")
        .mode = PolicyGraphMode::Draft;
    let mut missing_timestamp = distinct_policy(&source.canvases[0], "policy-no-live-time");
    missing_timestamp.live_updated_at = None;
    let mut padded_id = distinct_policy(&source.canvases[0], " policy-padded ");
    padded_id.title = "Padded".to_string();

    for policy in [oversized, draft_live, missing_timestamp, padded_id] {
        import_policies(
            &db,
            &PolicyTransferImportRequest {
                bundle: bundle(vec![policy], None),
                replace_all: false,
            },
        )
        .await
        .expect_err("invalid policy state must fail");
    }

    assert!(db.load_policy_workspace().await.expect("load").is_none());
    assert_eq!(db.current_change_sequence().await.expect("sequence"), 0);
}

#[tokio::test]
async fn import_rejects_layouts_that_normalized_storage_would_change() {
    let (_dir, db) = connect().await;
    let source = PolicyCanvasWorkspace::seeded();
    let base = distinct_policy(&source.canvases[0], "policy-layout");
    let mut duplicate = base.clone();
    duplicate
        .document
        .layout
        .nodes
        .push(duplicate.document.layout.nodes[0].clone());
    let mut dangling = base.clone();
    dangling.document.layout.nodes[0].node_id = "missing-layout-node".into();
    let mut reordered = base;
    reordered.document.layout.nodes.swap(0, 1);

    for policy in [duplicate, dangling, reordered] {
        import_policies(
            &db,
            &PolicyTransferImportRequest {
                bundle: bundle(vec![policy], None),
                replace_all: false,
            },
        )
        .await
        .expect_err("noncanonical layout must fail before persistence");
    }

    assert!(db.load_policy_workspace().await.expect("load").is_none());
    assert_eq!(db.current_change_sequence().await.expect("sequence"), 0);
}

#[tokio::test]
async fn merge_rejects_duplicate_special_roles_atomically() {
    let (_dir, db) = connect().await;
    let target = PolicyCanvasWorkspace::seeded();
    let mut incoming = distinct_policy(&target.canvases[0], "policy-second-manual-ocr");
    incoming.is_manual_ocr_paste_canvas = true;
    db.replace_policy_workspace(&target)
        .await
        .expect("seed target workspace");
    let sequence_before = db.current_change_sequence().await.expect("sequence before");

    import_policies(
        &db,
        &PolicyTransferImportRequest {
            bundle: bundle(vec![incoming], None),
            replace_all: false,
        },
    )
    .await
    .expect_err("duplicate special role must fail");

    assert_eq!(
        db.load_policy_workspace()
            .await
            .expect("workspace after reject"),
        Some(target),
    );
    assert_eq!(
        db.current_change_sequence().await.expect("sequence after"),
        sequence_before,
    );
}

#[tokio::test]
async fn replace_all_rejects_duplicate_scenario_ids() {
    let (_dir, db) = connect().await;
    let source = PolicyCanvasWorkspace::seeded();
    let mut duplicate_id = metadata(&source);
    duplicate_id.scenarios[1].id = duplicate_id.scenarios[0].id.clone();

    import_policies(
        &db,
        &PolicyTransferImportRequest {
            bundle: bundle(source.canvases.clone(), Some(duplicate_id)),
            replace_all: true,
        },
    )
    .await
    .expect_err("duplicate scenario metadata must fail");

    assert!(db.load_policy_workspace().await.expect("load").is_none());
    assert_eq!(db.current_change_sequence().await.expect("sequence"), 0);
}
