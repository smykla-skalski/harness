use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::*;
use crate::task_board::policy_graph::{PolicyCanvasWorkspace, PolicyGraph, PolicyGraphMode};
use crate::task_board::{TaskBoardGitRuntimeProfile, TaskBoardItem, TaskBoardStore};

#[tokio::test]
async fn managed_cutover_recovers_stage_and_archives_after_database_commit() {
    let legacy = tempdir().expect("legacy parent");
    let root = legacy.path().join("task-board");
    let store = TaskBoardStore::new(root.clone());
    let item = TaskBoardItem::new(
        "task-cutover".to_owned(),
        "Cut over".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    );
    store
        .create(&item.title, &item.body, item.clone())
        .expect("create legacy item");

    let prepared = prepare_managed_source(&root).expect("stage legacy board");
    assert!(prepared.staged);
    assert!(root.is_file());
    assert!(prepared.source.is_dir());
    let staged_path = prepared.source.clone();
    drop(prepared.locks);

    let recovered = prepare_managed_source(&root).expect("recover staged board");
    assert_eq!(recovered.source, staged_path);
    let snapshot = LegacyTaskBoardSnapshot::load(&recovered.source).expect("load stage");
    assert_eq!(snapshot.items, vec![item.clone()]);

    let database = tempdir().expect("database root");
    let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("open database");
    db.import_legacy_task_board(
        &snapshot,
        Some(&recovered.source),
        &TaskBoardGitRuntimeConfig::default(),
        None,
    )
    .await
    .expect("import stage");
    let marker = required_marker(&db).await.expect("import marker");
    archive_stage(&db, &recovered.source, &marker)
        .await
        .expect("archive stage");
    assert!(!recovered.source.exists());
    let completed = required_marker(&db).await.expect("completed marker");
    assert!(completed.archived_at.is_some());
    assert!(
        completed
            .archive_path
            .as_deref()
            .is_some_and(|path| Path::new(path).is_dir())
    );
    assert_eq!(
        db.task_board_item("task-cutover")
            .await
            .expect("database item"),
        item
    );
}

#[test]
fn multiple_stages_fail_closed() {
    let parent = tempdir().expect("legacy parent");
    let root = parent.path().join("task-board");
    fs::create_dir(parent.path().join(format!("{STAGE_PREFIX}one"))).expect("first stage");
    fs::create_dir(parent.path().join(format!("{STAGE_PREFIX}two"))).expect("second stage");
    let error = prepare_managed_source(&root)
        .err()
        .expect("ambiguous stages fail");
    assert!(error.to_string().contains("multiple legacy Task Board"));
}

#[test]
fn empty_cutover_keeps_a_recoverable_stage_until_database_commit() {
    let parent = tempdir().expect("legacy parent");
    let root = parent.path().join("task-board");

    let prepared = prepare_managed_source(&root).expect("prepare empty board");
    let stage = prepared.source.clone();
    assert!(prepared.staged);
    assert!(stage.is_dir());
    assert_eq!(fs::read_to_string(&root).expect("read sentinel"), SENTINEL);
    drop(prepared.locks);

    let recovered = prepare_managed_source(&root).expect("recover empty stage");
    assert_eq!(recovered.source, stage);
    assert!(
        LegacyTaskBoardSnapshot::load(&recovered.source)
            .expect("load empty stage")
            .items
            .is_empty()
    );
}

#[test]
fn recreated_root_with_orphan_stage_fails_closed() {
    let parent = tempdir().expect("legacy parent");
    let root = parent.path().join("task-board");
    fs::create_dir(&root).expect("recreated root");
    fs::create_dir(parent.path().join(format!("{STAGE_PREFIX}orphan"))).expect("orphan stage");

    let error = prepare_managed_source(&root)
        .err()
        .expect("root plus stage must fail");
    assert!(error.to_string().contains("root was recreated"));
}

#[test]
fn corrupted_sentinel_fails_closed() {
    let parent = tempdir().expect("legacy parent");
    let root = parent.path().join("task-board");
    fs::write(&root, "not the Harness sentinel").expect("write corrupt sentinel");
    fs::create_dir(parent.path().join(format!("{STAGE_PREFIX}one"))).expect("stage");

    let error = prepare_managed_source(&root)
        .err()
        .expect("corrupt sentinel must fail");
    assert!(error.to_string().contains("unexpected contents"));
}

#[tokio::test]
async fn existing_import_recreates_missing_sentinel_before_archival() {
    let parent = tempdir().expect("legacy parent");
    let root = parent.path().join("task-board");
    let prepared = prepare_managed_source(&root).expect("prepare empty board");
    let snapshot = LegacyTaskBoardSnapshot::load(&prepared.source).expect("load stage");
    let database = tempdir().expect("database root");
    let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("open database");
    db.import_legacy_task_board(
        &snapshot,
        Some(&prepared.source),
        &TaskBoardGitRuntimeConfig::default(),
        None,
    )
    .await
    .expect("import empty stage");
    fs::remove_file(&root).expect("remove sentinel at crash boundary");
    let marker = required_marker(&db).await.expect("marker");

    finalize_existing_import(&db, &root, &marker)
        .await
        .expect("finalize import");

    assert_eq!(fs::read_to_string(&root).expect("read sentinel"), SENTINEL);
    assert!(
        required_marker(&db)
            .await
            .expect("marker")
            .archived_at
            .is_some()
    );
}

#[tokio::test]
async fn existing_import_rejects_a_stage_changed_after_database_commit() {
    let parent = tempdir().expect("legacy parent");
    let root = parent.path().join("task-board");
    let store = TaskBoardStore::new(root.clone());
    let item = TaskBoardItem::new(
        "task-before-import".to_owned(),
        "Before import".to_owned(),
        "Original body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    );
    let item_title = item.title.clone();
    let item_body = item.body.clone();
    store
        .create(&item_title, &item_body, item)
        .expect("create legacy item");
    let prepared = prepare_managed_source(&root).expect("prepare legacy board");
    let snapshot = LegacyTaskBoardSnapshot::load(&prepared.source).expect("load staged board");
    let database = tempdir().expect("database root");
    let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("open database");
    db.import_legacy_task_board(
        &snapshot,
        Some(&prepared.source),
        &TaskBoardGitRuntimeConfig::default(),
        None,
    )
    .await
    .expect("import staged board");
    drop(prepared.locks);
    let changed_store = TaskBoardStore::new(prepared.source.clone());
    let changed = TaskBoardItem::new(
        "task-after-import".to_owned(),
        "After import".to_owned(),
        "Must not enter the archived source".to_owned(),
        "2026-07-11T10:01:00Z".to_owned(),
    );
    let changed_title = changed.title.clone();
    let changed_body = changed.body.clone();
    changed_store
        .create(&changed_title, &changed_body, changed)
        .expect("change staged board");
    let marker = required_marker(&db).await.expect("import marker");

    let error = finalize_existing_import(&db, &root, &marker)
        .await
        .expect_err("changed stage must fail closed");

    assert!(error.to_string().contains("source changed"));
    assert!(
        prepared.source.is_dir(),
        "changed stage must remain recoverable"
    );
    assert!(
        required_marker(&db)
            .await
            .expect("marker")
            .archived_at
            .is_none()
    );
}

#[tokio::test]
async fn direct_legacy_pipeline_upgrade_reaches_policy_database_before_archive() {
    let parent = tempdir().expect("legacy parent");
    let root = parent.path().join("task-board");
    fs::create_dir(&root).expect("legacy root");
    let mut document = PolicyGraph::seeded_v2();
    document.revision = 77;
    document.mode = PolicyGraphMode::Enforced;
    fs::write(
        root.join("policy-pipeline-v2.json"),
        serde_json::to_vec_pretty(&document).expect("encode policy"),
    )
    .expect("write legacy policy");
    let prepared = prepare_managed_source(&root).expect("stage policy board");
    let snapshot = LegacyTaskBoardSnapshot::load(&prepared.source).expect("load staged policy");
    let database = tempdir().expect("database root");
    let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("open database");
    db.import_legacy_task_board(
        &snapshot,
        Some(&prepared.source),
        &TaskBoardGitRuntimeConfig::default(),
        None,
    )
    .await
    .expect("import task board");

    import_legacy_policy_workspace(&db, &snapshot)
        .await
        .expect("import policy workspace");
    let imported = db
        .load_policy_workspace()
        .await
        .expect("load policy database")
        .expect("policy workspace");
    assert_eq!(
        imported.active_canvas().expect("active canvas").document,
        document
    );
    let marker = required_marker(&db).await.expect("marker");
    archive_stage(&db, &prepared.source, &marker)
        .await
        .expect("archive stage");
}

#[test]
fn direct_legacy_canvas_workspace_is_loaded_for_database_import() {
    let parent = tempdir().expect("legacy parent");
    let root = parent.path().join("task-board");
    fs::create_dir(&root).expect("legacy root");
    let mut workspace = PolicyCanvasWorkspace::seeded();
    workspace
        .active_canvas_mut()
        .expect("active canvas")
        .document
        .revision = 91;
    fs::write(
        root.join("policy-canvases-v1.json"),
        serde_json::to_vec_pretty(&workspace).expect("encode workspace"),
    )
    .expect("write workspace");

    let snapshot = LegacyTaskBoardSnapshot::load(&root).expect("load legacy workspace");
    assert_eq!(snapshot.policy_workspace, Some(workspace));
}

#[test]
fn acknowledging_recovery_retains_a_changed_secret_envelope() {
    let root = tempdir().expect("isolated root");
    with_isolated_harness_env(root.path(), || {
        let original = runtime_with_secret("original-secret");
        let digest = state::task_board_git_runtime_secret_handoff_digest(&original)
            .expect("digest")
            .expect("plaintext digest");
        write_runtime_config(&original);
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(async {
                let db = AsyncDaemonDb::connect(&root.path().join("handoff.db"))
                    .await
                    .expect("database");
                db.initialize_empty_task_board(&original.without_secret_metadata(), Some(&digest))
                    .await
                    .expect("initialize handoff");
                let marker = db
                    .pending_task_board_secret_handoff()
                    .await
                    .expect("marker")
                    .expect("pending handoff");
                let migration_id = marker.secret_handoff_id.expect("migration id");
                db.acknowledge_task_board_secret_handoff(&migration_id, &digest)
                    .await
                    .expect("acknowledging phase");
                write_runtime_config(&runtime_with_secret("replacement-secret"));

                let error = recover_acknowledging_secret_handoff(&db)
                    .await
                    .expect_err("changed envelope must fail closed");

                assert!(error.to_string().contains("payload changed"));
                assert!(
                    fs::read_to_string(state::config_path())
                        .expect("retained config")
                        .contains("replacement-secret")
                );
                assert_eq!(
                    db.pending_task_board_secret_handoff()
                        .await
                        .expect("pending marker")
                        .expect("handoff retained")
                        .secret_handoff_phase,
                    "acknowledging"
                );
            });
    });
}

#[test]
fn acknowledging_recovery_rejects_an_envelope_with_removed_plaintext() {
    let root = tempdir().expect("isolated root");
    with_isolated_harness_env(root.path(), || {
        let original = runtime_with_secret("original-secret");
        let digest = state::task_board_git_runtime_secret_handoff_digest(&original)
            .expect("digest")
            .expect("plaintext digest");
        write_runtime_config(&original);
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(async {
                let db = AsyncDaemonDb::connect(&root.path().join("handoff.db"))
                    .await
                    .expect("database");
                db.initialize_empty_task_board(&original.without_secret_metadata(), Some(&digest))
                    .await
                    .expect("initialize handoff");
                let marker = db
                    .pending_task_board_secret_handoff()
                    .await
                    .expect("marker")
                    .expect("pending handoff");
                let migration_id = marker.secret_handoff_id.expect("migration id");
                db.acknowledge_task_board_secret_handoff(&migration_id, &digest)
                    .await
                    .expect("acknowledging phase");
                write_runtime_config(&TaskBoardGitRuntimeConfig {
                    global: TaskBoardGitRuntimeProfile {
                        author_name: Some("Changed after acknowledgement".to_owned()),
                        ..Default::default()
                    },
                    repository_overrides: vec![],
                });

                let error = recover_acknowledging_secret_handoff(&db)
                    .await
                    .expect_err("missing plaintext digest must fail closed");

                assert!(error.to_string().contains("payload changed"));
                assert!(
                    fs::read_to_string(state::config_path())
                        .expect("retained config")
                        .contains("Changed after acknowledgement")
                );
                assert_eq!(
                    db.pending_task_board_secret_handoff()
                        .await
                        .expect("pending marker")
                        .expect("handoff retained")
                        .secret_handoff_phase,
                    "acknowledging"
                );
            });
    });
}

#[test]
fn completed_handoff_cleanup_retires_a_matching_residual_envelope() {
    let root = tempdir().expect("isolated root");
    with_isolated_harness_env(root.path(), || {
        let runtime = runtime_with_secret("residual-secret");
        let digest = state::task_board_git_runtime_secret_handoff_digest(&runtime)
            .expect("digest")
            .expect("plaintext digest");
        write_runtime_config(&runtime);
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(async {
                let db = AsyncDaemonDb::connect(&root.path().join("handoff.db"))
                    .await
                    .expect("database");
                db.initialize_empty_task_board(&runtime.without_secret_metadata(), Some(&digest))
                    .await
                    .expect("initialize handoff");
                let marker = db
                    .pending_task_board_secret_handoff()
                    .await
                    .expect("marker")
                    .expect("pending handoff");
                let migration_id = marker.secret_handoff_id.expect("migration id");
                db.acknowledge_task_board_secret_handoff(&migration_id, &digest)
                    .await
                    .expect("acknowledge");
                db.complete_task_board_secret_handoff(&migration_id)
                    .await
                    .expect("complete before simulated reboot");

                finish_secret_handoff_cleanup(&db)
                    .await
                    .expect("cleanup matching residual");

                assert!(
                    state::load_runtime_config_raw()
                        .expect("load config")
                        .expect("config remains")
                        .task_board_git_runtime_config
                        .is_none()
                );
            });
    });
}

fn runtime_with_secret(secret: &str) -> TaskBoardGitRuntimeConfig {
    TaskBoardGitRuntimeConfig {
        global: TaskBoardGitRuntimeProfile {
            ssh_private_key: Some(secret.to_string()),
            ..Default::default()
        },
        repository_overrides: vec![],
    }
}

fn write_runtime_config(runtime: &TaskBoardGitRuntimeConfig) {
    fs::create_dir_all(state::config_path().parent().expect("config parent"))
        .expect("create config parent");
    fs::write(
        state::config_path(),
        serde_json::to_vec_pretty(&state::DaemonRuntimeConfig {
            log_level: Some("debug".into()),
            task_board_git_runtime_config: Some(runtime.clone()),
        })
        .expect("encode runtime config"),
    )
    .expect("write runtime config");
}
