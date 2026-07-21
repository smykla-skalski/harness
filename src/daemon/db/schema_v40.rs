use rusqlite::Connection;

use super::CliError;

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    super::schema_repairs_reconciliation_cursors::repair_and_stamp(conn)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
    use sqlx::query_scalar;
    use tempfile::tempdir;

    #[test]
    fn migration_is_restart_safe_and_preserves_cursor_state() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        db.connection()
            .execute_batch(
                "DROP TABLE task_board_reconciliation_cursors;
                 UPDATE schema_meta SET value = '39' WHERE key = 'version';",
            )
            .expect("restore v39 shape");

        run(db.connection()).expect("migrate reconciliation cursor");
        db.connection()
            .execute(
                "INSERT INTO task_board_reconciliation_cursors (
                     queue, sort_updated_at, sort_execution_id
                 ) VALUES ('read_only_recoverable', '2026-07-18T10:00:00Z', 'execution-a')",
                [],
            )
            .expect("seed cursor");
        run(db.connection()).expect("repeat reconciliation cursor migration");

        assert_eq!(db.schema_version().expect("schema version"), "40");
        let row: (String, String) = db
            .connection()
            .query_row(
                "SELECT sort_updated_at, sort_execution_id
                 FROM task_board_reconciliation_cursors
                 WHERE queue = 'read_only_recoverable'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("read preserved cursor");
        assert_eq!(row, ("2026-07-18T10:00:00Z".into(), "execution-a".into()));
    }

    #[test]
    fn migration_refuses_incompatible_cursor_table_without_replacing_it() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        db.connection()
            .execute_batch(
                "DROP TABLE task_board_reconciliation_cursors;
                 CREATE TABLE task_board_reconciliation_cursors (
                     queue TEXT PRIMARY KEY,
                     sort_execution_id TEXT NOT NULL,
                     sentinel TEXT NOT NULL
                 ) WITHOUT ROWID;
                 INSERT INTO task_board_reconciliation_cursors
                     (queue, sort_execution_id, sentinel)
                 VALUES ('read_only_recoverable', 'execution-a', 'keep');
                 UPDATE schema_meta SET value = '39' WHERE key = 'version';",
            )
            .expect("seed incompatible cursor table");

        let error = run(db.connection()).expect_err("incompatible table must fail closed");

        assert!(error.to_string().contains("refusing destructive repair"));
        let sentinel: String = db
            .connection()
            .query_row(
                "SELECT sentinel FROM task_board_reconciliation_cursors",
                [],
                |row| row.get(0),
            )
            .expect("read preserved sentinel");
        assert_eq!(sentinel, "keep");
        assert_eq!(db.schema_version().expect("schema version"), "39");
    }

    #[tokio::test]
    async fn async_connect_repairs_missing_current_cursor_table_and_records_migration() {
        let temp = tempdir().expect("tempdir");
        let path = temp.path().join("harness.db");
        let sync_db = DaemonDb::open(&path).expect("open current sync db");
        sync_db
            .connection()
            .execute("DROP TABLE task_board_reconciliation_cursors", [])
            .expect("drop current cursor table");
        assert_eq!(sync_db.schema_version().expect("schema version"), "42");
        drop(sync_db);

        let async_db = AsyncDaemonDb::connect(&path)
            .await
            .expect("repair current schema before async connect");

        let table_count: i64 = query_scalar(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'task_board_reconciliation_cursors'",
        )
        .fetch_one(async_db.pool())
        .await
        .expect("count repaired cursor table");
        assert_eq!(table_count, 1);
        let migration_count: i64 =
            query_scalar("SELECT COUNT(*) FROM _sqlx_migrations WHERE version = 34")
                .fetch_one(async_db.pool())
                .await
                .expect("count v40 async migration ledger row");
        assert_eq!(migration_count, 1);
    }

    #[tokio::test]
    async fn async_connect_refuses_malformed_current_cursor_table_without_replacing_it() {
        let temp = tempdir().expect("tempdir");
        let path = temp.path().join("harness.db");
        let sync_db = DaemonDb::open(&path).expect("open current sync db");
        sync_db
            .connection()
            .execute_batch(
                "DROP TABLE task_board_reconciliation_cursors;
                 CREATE TABLE task_board_reconciliation_cursors (
                     queue TEXT PRIMARY KEY,
                     sort_execution_id TEXT NOT NULL,
                     sentinel TEXT NOT NULL
                 ) WITHOUT ROWID;
                 INSERT INTO task_board_reconciliation_cursors
                     (queue, sort_execution_id, sentinel)
                 VALUES ('read_only_recoverable', 'execution-a', 'keep');",
            )
            .expect("seed malformed current cursor table");
        assert_eq!(sync_db.schema_version().expect("schema version"), "42");
        drop(sync_db);

        let error = AsyncDaemonDb::connect(&path)
            .await
            .expect_err("malformed current cursor table must fail closed");

        assert!(error.to_string().contains("refusing destructive repair"));
        let connection = Connection::open(&path).expect("reopen malformed database");
        let sentinel: String = connection
            .query_row(
                "SELECT sentinel FROM task_board_reconciliation_cursors",
                [],
                |row| row.get(0),
            )
            .expect("read preserved sentinel");
        assert_eq!(sentinel, "keep");
    }
}
