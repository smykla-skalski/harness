use tempfile::tempdir;

use super::*;

#[tokio::test]
async fn async_connect_repairs_missing_orchestrator_settings_singleton() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    let deleted = sync_db
        .connection()
        .execute(
            "DELETE FROM task_board_orchestrator_settings WHERE singleton = 1",
            [],
        )
        .expect("delete orchestrator settings singleton");
    assert_eq!(deleted, 1);
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("repair orchestrator settings singleton");
    let (settings_json, revision): (String, i64) = sqlx::query_as(
        "SELECT settings_json, revision
         FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("read repaired orchestrator settings");

    assert_eq!(
        settings_json,
        r#"{"admission_policy":{"limits":[],"windows":[]}}"#
    );
    assert_eq!(revision, 1);
    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        SCHEMA_VERSION
    );
}

#[tokio::test]
async fn async_connect_repairs_missing_dispatch_compensation_marker() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    crate::daemon::db::schema_v43::restore_legacy_v40_for_test(&sync_db);
    sync_db
        .connection()
        .execute_batch(
            "ALTER TABLE task_board_dispatch_intents DROP COLUMN compensation_pending;
             UPDATE schema_meta SET value = '38' WHERE key = 'version';",
        )
        .expect("remove compensation marker");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("repair dispatch compensation marker");
    let column: (String, i64, Option<String>) = sqlx::query_as(
        "SELECT type, \"notnull\", dflt_value
         FROM pragma_table_xinfo('task_board_dispatch_intents')
         WHERE name = 'compensation_pending'",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("read repaired compensation marker");

    assert_eq!(column, ("INTEGER".to_string(), 1, Some("0".to_string())));
}
