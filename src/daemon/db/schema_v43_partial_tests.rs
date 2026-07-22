use sqlx::query_scalar;
use tempfile::tempdir;

use super::tests::{legacy_v40_fixture, legacy_v40_fixture_at};
use super::*;
use crate::daemon::db::AsyncDaemonDb;

#[test]
fn sync_upgrade_repairs_partial_v40_admission_before_rebuild() {
    let db = legacy_v40_fixture();
    remove_admission_objects(db.connection());

    run(db.connection()).expect("repair v40 admission then migrate v41");

    assert_eq!(db.schema_version().expect("schema version"), "43");
    assert_admission_objects_exist(db.connection());
}

#[tokio::test]
async fn async_upgrade_repairs_partial_v40_admission_before_pool_open() {
    let temp = tempdir().expect("tempdir");
    let path = temp.path().join("harness.db");
    let db = legacy_v40_fixture_at(&path);
    remove_admission_objects(db.connection());
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("repair and migrate before async pool open");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        "43"
    );
    let admission_tables: i64 = query_scalar(
        "SELECT COUNT(*) FROM sqlite_master
         WHERE type = 'table'
           AND name IN (
             'task_board_dispatch_admission_decisions',
             'task_board_dispatch_admission_ledger'
           )",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("count repaired admission tables");
    assert_eq!(admission_tables, 2);
}

#[test]
fn repair_refuses_case_corrupted_active_predicate() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    db.connection()
        .execute_batch(
            "DROP INDEX task_board_remote_assignments_active_host;
             CREATE INDEX task_board_remote_assignments_active_host
             ON task_board_remote_assignments(
                 host_id, state, lease_expires_at, deadline_at, assignment_id
             )
             WHERE state IN ('offered', 'claimed', 'started', 'running', 'UNKNOWN');",
        )
        .expect("corrupt case-sensitive active predicate");

    let error = run(db.connection()).expect_err("case-corrupted predicate must be refused");

    assert!(
        error
            .to_string()
            .contains("incompatible remote execution index")
    );
    let stored: String = db
        .connection()
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE name = 'task_board_remote_assignments_active_host'",
            [],
            |row| row.get(0),
        )
        .expect("read preserved corrupted index");
    assert!(stored.contains("'UNKNOWN'"));
}

fn remove_admission_objects(conn: &rusqlite::Connection) {
    conn.execute_batch(
        "DROP TABLE task_board_dispatch_admission_ledger;
         DROP TABLE task_board_dispatch_admission_decisions;
         DROP INDEX task_board_dispatch_intents_admission_identity;",
    )
    .expect("remove repairable v40 admission objects");
}

fn assert_admission_objects_exist(conn: &rusqlite::Connection) {
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE (
                 type = 'table'
                 AND name IN (
                     'task_board_dispatch_admission_decisions',
                     'task_board_dispatch_admission_ledger'
                 )
             ) OR (
                 type = 'index'
                 AND name = 'task_board_dispatch_intents_admission_identity'
             )",
            [],
            |row| row.get(0),
        )
        .expect("count repaired admission objects");
    assert_eq!(count, 3);
}
