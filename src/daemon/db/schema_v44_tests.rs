use sqlx::query_scalar;
use tempfile::tempdir;

use super::{run, shape_needs_repair};
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, SCHEMA_VERSION};

#[test]
fn fresh_schema_includes_v44_lane_ordering() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    let columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_items')
             WHERE name IN ('lane_position', 'lane_origin', 'lane_actor', 'lane_producer',
                            'lane_set_at')",
            [],
            |row| row.get(0),
        )
        .expect("inspect fresh lane columns");

    assert_eq!(columns, 5);
    assert_eq!(db.schema_version().expect("schema version"), SCHEMA_VERSION);
}

#[test]
fn v43_database_migrates_through_lane_v44_to_current_and_restarts() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current database");
    db.connection()
        .execute_batch(
            "DROP TRIGGER task_board_items_lane_coherence_insert;
             DROP TRIGGER task_board_items_lane_coherence_update;
             DROP INDEX task_board_items_live_lane_position;
             DROP INDEX task_board_items_live_lane_order;
             ALTER TABLE task_board_items DROP COLUMN lane_set_at;
             ALTER TABLE task_board_items DROP COLUMN lane_producer;
             ALTER TABLE task_board_items DROP COLUMN lane_actor;
             ALTER TABLE task_board_items DROP COLUMN lane_origin;
             ALTER TABLE task_board_items DROP COLUMN lane_position;
             UPDATE schema_meta SET value = '43' WHERE key = 'version';",
        )
        .expect("restore v43 schema");
    drop(db);

    let reopened = DaemonDb::open(&path).expect("migrate v43 database");
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        SCHEMA_VERSION
    );
    drop(reopened);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");
    assert_eq!(
        restarted.schema_version().expect("schema version"),
        SCHEMA_VERSION
    );
}

#[tokio::test]
async fn async_upgrade_records_remote_v43_lane_v44_and_integrity_v45_migrations() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current remote v43 database");
    db.connection()
        .execute_batch(
            "DROP TRIGGER task_board_items_lane_coherence_insert;
             DROP TRIGGER task_board_items_lane_coherence_update;
             DROP INDEX task_board_items_live_lane_position;
             DROP INDEX task_board_items_live_lane_order;
             ALTER TABLE task_board_items DROP COLUMN lane_set_at;
             ALTER TABLE task_board_items DROP COLUMN lane_producer;
             ALTER TABLE task_board_items DROP COLUMN lane_actor;
             ALTER TABLE task_board_items DROP COLUMN lane_origin;
             ALTER TABLE task_board_items DROP COLUMN lane_position;
             UPDATE schema_meta SET value = '43' WHERE key = 'version';",
        )
        .expect("restore remote v43 schema");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade remote v43 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        SCHEMA_VERSION
    );
    let migrations: Vec<i64> = query_scalar(
        "SELECT version FROM _sqlx_migrations WHERE version IN (37, 38, 39) ORDER BY version",
    )
    .fetch_all(async_db.pool())
    .await
    .expect("read migration ledger");
    assert_eq!(migrations, vec![37, 38, 39]);
}

#[test]
fn v44_repair_rebuilds_missing_lane_indexes() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.connection()
        .execute_batch(
            "DROP INDEX task_board_items_live_lane_position;
             DROP INDEX task_board_items_live_lane_order;",
        )
        .expect("drop lane indexes");

    assert!(shape_needs_repair(db.connection()).expect("inspect repair need"));
    run(db.connection()).expect("repair lane indexes");
    assert!(!shape_needs_repair(db.connection()).expect("inspect repaired shape"));
    assert_eq!(db.schema_version().expect("schema version"), "44");
}
