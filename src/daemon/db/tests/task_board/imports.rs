use tempfile::tempdir;

use super::*;
use crate::task_board::legacy_import::LegacyTaskBoardSnapshot;
use crate::task_board::{
    TaskBoardGitRuntimeConfig, TaskBoardItem, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorState, TaskBoardStore,
};

#[tokio::test]
async fn legacy_snapshot_import_is_atomic_and_idempotent() {
    let legacy = tempdir().expect("legacy root");
    let store = TaskBoardStore::new(legacy.path().to_path_buf());
    let item = TaskBoardItem::new(
        "task-imported".to_owned(),
        "Imported".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    );
    store
        .create(&item.title, &item.body, item.clone())
        .expect("write legacy item");
    crate::infra::io::write_json_pretty(
        &legacy.path().join("orchestrator-settings.json"),
        &TaskBoardOrchestratorSettings::default(),
    )
    .expect("write settings");
    crate::infra::io::write_json_pretty(
        &legacy.path().join("orchestrator-state.json"),
        &TaskBoardOrchestratorState::default(),
    )
    .expect("write state");
    let snapshot = LegacyTaskBoardSnapshot::load(legacy.path()).expect("load snapshot");
    assert_eq!(snapshot.items.len(), 1);

    let database = tempdir().expect("database root");
    let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("open db");
    let runtime_config = TaskBoardGitRuntimeConfig::default();
    let imported = db
        .import_legacy_task_board(&snapshot, Some(legacy.path()), &runtime_config, None)
        .await
        .expect("import snapshot");
    assert!(imported.imported);
    assert!(imported.change_revision > 0);
    assert_eq!(
        db.task_board_item(&item.id).await.expect("imported item"),
        item
    );

    let repeated = db
        .import_legacy_task_board(&snapshot, Some(legacy.path()), &runtime_config, None)
        .await
        .expect("repeat import");
    assert!(!repeated.imported);

    sqlx::query(
        "UPDATE task_board_imports
        SET canonical_model_digest = 'changed-canonical-model'
        WHERE source_kind = 'legacy_global_board'",
    )
    .execute(db.pool())
    .await
    .expect("change legacy canonical digest");
    let error = db
        .import_legacy_task_board(&snapshot, Some(legacy.path()), &runtime_config, None)
        .await
        .expect_err("changed legacy canonical model must fail closed");
    assert!(error.to_string().contains("source changed"));
}

#[tokio::test]
async fn empty_database_import_allows_default_model_evolution_but_rejects_source_changes() {
    let database = tempdir().expect("database root");
    let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("open db");
    let runtime_config = TaskBoardGitRuntimeConfig::default();
    let imported = db
        .initialize_empty_task_board(&runtime_config, None)
        .await
        .expect("initialize empty task board");
    assert!(imported.imported);
    let item = TaskBoardItem::new(
        "task-after-empty-import".to_owned(),
        "Preserved".to_owned(),
        "Existing database contents remain authoritative.".to_owned(),
        "2026-07-16T17:43:00Z".to_owned(),
    );
    db.create_task_board_item(item.clone())
        .await
        .expect("create database item");

    let prior_canonical_digest = concat!(
        "d6b8cc9bca25924b07943cdf7fe9c5111",
        "18cd68af29f469db4dc6d1005f33928"
    );
    sqlx::query(
        "UPDATE task_board_imports
        SET canonical_model_digest = ?1
        WHERE source_kind = 'empty_database'",
    )
    .bind(prior_canonical_digest)
    .execute(db.pool())
    .await
    .expect("simulate prior default model");
    let repeated = db
        .initialize_empty_task_board(&runtime_config, None)
        .await
        .expect("accept prior default model");
    assert!(!repeated.imported);
    assert_eq!(
        db.task_board_item(&item.id).await.expect("preserved item"),
        item
    );
    assert_eq!(
        db.task_board_import_marker("empty_database")
            .await
            .expect("marker")
            .expect("empty import marker")
            .canonical_model_digest,
        prior_canonical_digest
    );

    sqlx::query(
        "UPDATE task_board_imports
        SET source_digest = 'changed-source'
        WHERE source_kind = 'empty_database'",
    )
    .execute(db.pool())
    .await
    .expect("change source digest");
    let error = db
        .initialize_empty_task_board(&runtime_config, None)
        .await
        .expect_err("changed empty source must fail closed");
    assert!(error.to_string().contains("source changed"));
}
