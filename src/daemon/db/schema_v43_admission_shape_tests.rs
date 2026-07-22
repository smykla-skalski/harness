use sqlx::query_scalar;
use tempfile::tempdir;

use super::tests::{legacy_v40_fixture, legacy_v40_fixture_at};
use super::*;
use crate::daemon::db::AsyncDaemonDb;

const DISPATCH_ADMISSION_INDEXES: &[&str] = &[
    "task_board_dispatch_intents_admission_identity",
    "idx_task_board_dispatch_intents_pending",
    "idx_task_board_dispatch_session_work_item",
    "idx_task_board_dispatch_active_item",
    "task_board_dispatch_admission_decisions_current_intent",
    "task_board_dispatch_admission_decisions_current_item",
    "task_board_dispatch_admission_decisions_item_history",
    "task_board_dispatch_admission_ledger_current_requirement",
    "task_board_dispatch_admission_ledger_usage",
    "task_board_dispatch_admission_ledger_intent_generation",
];

const ADMISSION_TABLES: &[&str] = &[
    "task_board_dispatch_admission_decisions",
    "task_board_dispatch_admission_ledger",
];

#[test]
fn fresh_and_repaired_sync_v43_require_every_dispatch_admission_index() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    assert_indexes_sync(db.connection());

    drop_indexes(db.connection());
    run(db.connection()).expect("repair every missing dispatch admission index");

    assert_indexes_sync(db.connection());
}

#[tokio::test]
async fn fresh_and_repaired_async_v43_require_every_dispatch_admission_index() {
    let temp = tempdir().expect("tempdir");
    let path = temp.path().join("harness.db");
    let db = legacy_v40_fixture_at(&path);
    run(db.connection()).expect("migrate strict remote execution ledger");
    drop_indexes(db.connection());
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("repair indexes before async pool opens");

    assert_indexes_async(&async_db).await;
}

#[test]
fn sync_v43_refuses_lost_dispatch_uniqueness_and_both_malformed_admission_tables() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    db.connection()
        .execute(
            "DROP INDEX task_board_remote_assignments_identity_epoch",
            [],
        )
        .expect("drop an earlier repairable index");
    corrupt_dispatch_uniqueness(db.connection());

    let error = run(db.connection()).expect_err("lost dispatch uniqueness must be refused");
    assert!(
        error
            .to_string()
            .contains("incompatible remote execution index")
    );

    for table in ADMISSION_TABLES {
        let db = legacy_v40_fixture();
        run(db.connection()).expect("migrate strict remote execution ledger");
        corrupt_table(db.connection(), *table);

        let error =
            crate::daemon::db::schema_repairs_remote_execution::repair_and_stamp(db.connection())
                .expect_err("remote repair must fingerprint both admission tables");
        assert!(
            error
                .to_string()
                .contains("incompatible remote execution ledger schema"),
            "{table}: {error}"
        );
        assert!(column_exists(db.connection(), *table, "sentinel"));
    }
}

#[tokio::test]
async fn async_v43_refuses_lost_uniqueness_and_both_malformed_admission_tables() {
    assert_async_corruption_refused(None).await;
    for table in ADMISSION_TABLES {
        assert_async_corruption_refused(Some(*table)).await;
    }
}

fn assert_indexes_sync(conn: &rusqlite::Connection) {
    for name in DISPATCH_ADMISSION_INDEXES {
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1",
                [*name],
                |row| row.get(0),
            )
            .expect("count dispatch admission index");
        assert_eq!(count, 1, "missing {name}");
    }
}

async fn assert_indexes_async(db: &AsyncDaemonDb) {
    for name in DISPATCH_ADMISSION_INDEXES {
        let count: i64 =
            query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1")
                .bind(*name)
                .fetch_one(db.pool())
                .await
                .expect("count dispatch admission index");
        assert_eq!(count, 1, "missing {name}");
    }
}

fn drop_indexes(conn: &rusqlite::Connection) {
    for name in DISPATCH_ADMISSION_INDEXES {
        conn.execute(&format!("DROP INDEX {name}"), [])
            .expect("drop dispatch admission index");
    }
}

fn corrupt_dispatch_uniqueness(conn: &rusqlite::Connection) {
    conn.execute_batch(
        "DROP INDEX idx_task_board_dispatch_session_work_item;
         CREATE INDEX idx_task_board_dispatch_session_work_item
         ON task_board_dispatch_intents(session_id, work_item_id);",
    )
    .expect("replace unique dispatch identity with a nonunique index");
}

fn corrupt_table(conn: &rusqlite::Connection, table: &str) {
    conn.execute(&format!("ALTER TABLE {table} ADD COLUMN sentinel TEXT"), [])
        .expect("malform admission table");
}

fn column_exists(conn: &rusqlite::Connection, table: &str, column: &str) -> bool {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2)",
        rusqlite::params![table, column],
        |row| row.get(0),
    )
    .expect("inspect malformed admission table")
}

async fn assert_async_corruption_refused(table: Option<&str>) {
    let temp = tempdir().expect("tempdir");
    let path = temp.path().join("harness.db");
    let db = legacy_v40_fixture_at(&path);
    run(db.connection()).expect("migrate strict remote execution ledger");
    if let Some(table) = table {
        corrupt_table(db.connection(), table);
    } else {
        corrupt_dispatch_uniqueness(db.connection());
    }
    drop(db);

    let error = match AsyncDaemonDb::connect(&path).await {
        Ok(_) => panic!("corrupted v43 shape must be refused"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("incompatible"), "{error}");
}
