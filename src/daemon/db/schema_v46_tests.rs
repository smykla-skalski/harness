use sqlx::query_scalar;
use tempfile::tempdir;

use super::super::schema_repairs_triage::shape_needs_repair;
use super::run;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

const DROP_V46_SQL: &str = "
DROP INDEX task_board_triage_decisions_item_history;
DROP INDEX task_board_triage_decisions_current;
DROP TABLE task_board_triage_decisions;
ALTER TABLE task_board_items DROP COLUMN tombstone_cause;
UPDATE schema_meta SET value = '45' WHERE key = 'version';";

#[test]
fn fresh_schema_includes_v46_triage_objects() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    let column: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_items')
             WHERE name = 'tombstone_cause'",
            [],
            |row| row.get(0),
        )
        .expect("inspect fresh tombstone_cause column");
    assert_eq!(column, 1);

    let table: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'task_board_triage_decisions'",
            [],
            |row| row.get(0),
        )
        .expect("inspect fresh triage decisions table");
    assert_eq!(table, 1);
    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

#[test]
fn v45_database_migrates_to_v46_and_restarts() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current database");
    db.connection()
        .execute_batch(DROP_V46_SQL)
        .expect("restore v45 schema");
    drop(db);

    let reopened = DaemonDb::open(&path).expect("migrate v45 database");
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    drop(reopened);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");
    assert_eq!(
        restarted.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

#[tokio::test]
async fn async_upgrade_records_v45_then_v46_migrations() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v45 database");
    db.connection()
        .execute_batch(DROP_V46_SQL)
        .expect("restore v45 schema");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v45 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    let migrations: Vec<i64> = query_scalar(
        "SELECT version FROM _sqlx_migrations WHERE version IN (39, 40) ORDER BY version",
    )
    .fetch_all(async_db.pool())
    .await
    .expect("read migration ledger");
    assert_eq!(migrations, vec![39, 40]);
}

#[test]
fn v46_repair_rebuilds_missing_triage_objects() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.connection()
        .execute_batch(
            "DROP INDEX task_board_triage_decisions_item_history;
             DROP INDEX task_board_triage_decisions_current;
             DROP TABLE task_board_triage_decisions;",
        )
        .expect("drop triage decision objects");

    assert!(shape_needs_repair(db.connection()).expect("inspect repair need"));
    run(db.connection()).expect("repair triage decision objects");
    assert!(!shape_needs_repair(db.connection()).expect("inspect repaired shape"));
    assert_eq!(db.schema_version().expect("schema version"), "46");
}

#[test]
fn v46_refuses_destructive_repair_over_an_incompatible_tombstone_cause_column() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.connection()
        .execute_batch(
            "DROP INDEX task_board_triage_decisions_item_history;
             DROP INDEX task_board_triage_decisions_current;
             DROP TABLE task_board_triage_decisions;
             ALTER TABLE task_board_items DROP COLUMN tombstone_cause;
             ALTER TABLE task_board_items ADD COLUMN tombstone_cause INTEGER NOT NULL DEFAULT 0;",
        )
        .expect("install an incompatible tombstone_cause column");

    let repair_error = run(db.connection()).expect_err("refuse destructive repair");
    assert!(
        repair_error
            .to_string()
            .contains("refusing destructive repair"),
        "unexpected error: {repair_error}"
    );
}

#[test]
fn v46_triage_decisions_reject_malformed_evidence_fingerprint() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.connection()
        .execute(
            "INSERT INTO task_board_items (
                 item_id, schema_version, title, body, status, priority, tags_json,
                 project_id, target_project_types_json, agent_mode, imported_from_provider,
                 planning_json, workflow_json, session_id, work_item_id, usage_json,
                 created_at, updated_at, deleted_at, revision, workflow_kind
             ) VALUES (
                 'item-1', 1, 'Title', '', 'backlog', 'medium', '[]',
                 NULL, '[]', 'headless', NULL, '{}', '{}', NULL, NULL, '{}',
                 '2026-07-22T00:00:00Z', '2026-07-22T00:00:00Z', NULL, 1,
                 'default_task'
             )",
            [],
        )
        .expect("seed one task board item");

    let insert_result = db.connection().execute(
        "INSERT INTO task_board_triage_decisions (
             decision_id, item_id, generation, verdict, reason_code, evaluator_identity,
             evaluator_version, evidence_fingerprint, cause, decided_at
         ) VALUES ('decision-1', 'item-1', 1, 'todo', 'meaningful_label',
                   'task_board.triage.builtin_v1', 1, 'not-a-fingerprint', 'initial',
                   '2026-07-22T00:00:00Z')",
        [],
    );
    assert!(
        insert_result.is_err(),
        "malformed evidence fingerprint must be rejected by the CHECK constraint"
    );
}
