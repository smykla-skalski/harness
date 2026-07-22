use tempfile::tempdir;

use super::*;
use crate::task_board::legacy_import::LegacyTaskBoardSnapshot;
use crate::task_board::{
    TaskBoardGitRuntimeConfig, TaskBoardItem, TaskBoardLaneOrigin, TaskBoardOrchestratorSettings,
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
async fn imported_explicit_lane_anchor_survives_restart_and_records_the_item_sequence() {
    let legacy = tempdir().expect("legacy root");
    let store = TaskBoardStore::new(legacy.path().to_path_buf());
    let mut item = TaskBoardItem::new(
        "task-imported-anchor".to_owned(),
        "Imported anchor".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    );
    item.lane_position = Some(0);
    item.lane_origin = Some(TaskBoardLaneOrigin::Manual {
        actor: "legacy-control".into(),
    });
    item.lane_set_at = Some("2026-07-11T10:00:00Z".into());
    store
        .create(&item.title, &item.body, item.clone())
        .expect("write legacy anchor");
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
    let database = tempdir().expect("database root");
    let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("open db");
    db.import_legacy_task_board(
        &snapshot,
        Some(legacy.path()),
        &TaskBoardGitRuntimeConfig::default(),
        None,
    )
    .await
    .expect("import snapshot");
    let sequence: i64 = sqlx::query_scalar(
        "SELECT change_seq FROM change_tracking WHERE scope = 'task_board:items'",
    )
    .fetch_one(db.pool())
    .await
    .expect("item sequence");
    let audit_sequence: i64 = sqlx::query_scalar(
        "SELECT json_extract(payload_json, '$.items_change_seq') FROM audit_events
         WHERE subject = ?1 AND kind = 'task_board.item.lane_position_changed'",
    )
    .bind(&item.id)
    .fetch_one(db.pool())
    .await
    .expect("lane import audit");
    assert_eq!(audit_sequence, sequence);
    drop(db);
    let restarted = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("restart database");
    let restored = restarted.task_board_item(&item.id).await.expect("restored item");
    assert_eq!(restored.lane_position, Some(0));
    assert!(matches!(
        restored.lane_origin,
        Some(TaskBoardLaneOrigin::Manual { .. })
    ));
}

#[tokio::test]
async fn import_materializes_reverse_filename_anchors_before_persistence() {
    let legacy = tempdir().expect("legacy root");
    let store = TaskBoardStore::new(legacy.path().to_path_buf());
    store
        .create("A", "Body", anchored_item("a", 1))
        .expect("write later anchor");
    store
        .create("B", "Body", anchored_item("b", 0))
        .expect("write first anchor");
    write_legacy_metadata(legacy.path());
    let snapshot = LegacyTaskBoardSnapshot::load(legacy.path()).expect("load snapshot");
    assert_eq!(
        snapshot.items.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(),
        ["a", "b"],
        "legacy load is filename ordered"
    );
    let database = tempdir().expect("database root");
    let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("open db");
    db.import_legacy_task_board(
        &snapshot,
        Some(legacy.path()),
        &TaskBoardGitRuntimeConfig::default(),
        None,
    )
    .await
    .expect("import materialized anchors");
    let imported = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(
        imported
            .items
            .iter()
            .map(|item| item.item.id.as_str())
            .collect::<Vec<_>>(),
        ["b", "a"]
    );
    let (audit_count, audit_sequences): (i64, i64) = sqlx::query_as(
        "SELECT COUNT(*), COUNT(DISTINCT json_extract(payload_json, '$.items_change_seq'))
         FROM audit_events WHERE kind = 'task_board.item.lane_position_changed'",
    )
    .fetch_one(db.pool())
    .await
    .expect("import audits");
    assert_eq!((audit_count, audit_sequences), (2, 1));
    drop(db);
    let restarted = AsyncDaemonDb::connect(&database.path().join("harness.db"))
        .await
        .expect("restart database");
    let restored = restarted.task_board_items_snapshot(None).await.expect("restored snapshot");
    assert_eq!(
        restored
            .items
            .iter()
            .map(|item| item.item.id.as_str())
            .collect::<Vec<_>>(),
        ["b", "a"]
    );
}

#[tokio::test]
async fn import_rejects_duplicate_and_out_of_range_lane_anchors() {
    for (name, items, expected) in [
        (
            "duplicate",
            vec![anchored_item("duplicate-a", 0), anchored_item("duplicate-b", 0)],
            "unique",
        ),
        (
            "out-of-range",
            vec![anchored_item("out-of-range", 1)],
            "cardinality",
        ),
    ] {
        let legacy = tempdir().expect("legacy root");
        let store = TaskBoardStore::new(legacy.path().to_path_buf());
        for item in items {
            let title = item.title.clone();
            let body = item.body.clone();
            store
                .create(&title, &body, item)
                .expect("write invalid anchor");
        }
        write_legacy_metadata(legacy.path());
        let snapshot = LegacyTaskBoardSnapshot::load(legacy.path()).expect("load snapshot");
        let database = tempdir().expect("database root");
        let db = AsyncDaemonDb::connect(&database.path().join("harness.db"))
            .await
            .expect("open db");
        let error = db
            .import_legacy_task_board(
                &snapshot,
                Some(legacy.path()),
                &TaskBoardGitRuntimeConfig::default(),
                None,
            )
            .await
            .expect_err("invalid snapshot anchor must fail");
        assert!(error.to_string().contains(expected), "case {name}: {error}");
    }
}

fn anchored_item(id: &str, lane_position: u32) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        id.into(),
        "Body".into(),
        "2026-07-11T10:00:00Z".into(),
    );
    item.lane_position = Some(lane_position);
    item.lane_origin = Some(TaskBoardLaneOrigin::Manual {
        actor: "legacy-control".into(),
    });
    item.lane_set_at = Some("2026-07-11T10:00:00Z".into());
    item
}

fn write_legacy_metadata(root: &std::path::Path) {
    crate::infra::io::write_json_pretty(
        &root.join("orchestrator-settings.json"),
        &TaskBoardOrchestratorSettings::default(),
    )
    .expect("write settings");
    crate::infra::io::write_json_pretty(
        &root.join("orchestrator-state.json"),
        &TaskBoardOrchestratorState::default(),
    )
    .expect("write state");
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
