use tempfile::tempdir;

use super::*;

const WAKE_TABLE_SQL: &str = "
CREATE TABLE task_board_orchestrator_wake_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    cause TEXT NOT NULL,
    entity_id TEXT,
    entity_revision INTEGER,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    processed_at TEXT
)";

#[tokio::test]
async fn async_connect_repairs_missing_wake_event_table_and_index() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute("DROP TABLE task_board_orchestrator_wake_events", [])
        .expect("drop wake-event table");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("repair wake-event table");
    let objects: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master
         WHERE (type = 'table' AND name = 'task_board_orchestrator_wake_events')
            OR (type = 'index' AND name = 'task_board_orchestrator_wake_events_pending')",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("inspect repaired wake-event objects");

    assert_eq!(objects, 2);
}

#[tokio::test]
async fn async_connect_repairs_missing_wake_event_pending_index() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute("DROP INDEX task_board_orchestrator_wake_events_pending", [])
        .expect("drop wake-event pending index");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("repair wake-event pending index");
    let columns: Vec<String> = sqlx::query_scalar(
        "SELECT name FROM pragma_index_xinfo('task_board_orchestrator_wake_events_pending')
         WHERE key = 1 ORDER BY seqno",
    )
    .fetch_all(async_db.pool())
    .await
    .expect("inspect repaired wake-event pending index");

    assert_eq!(columns, ["processed_at", "sequence"]);
}

#[tokio::test]
async fn async_connect_refuses_incompatible_wake_event_table_shapes() {
    for (case, sql) in [
        (
            "missing autoincrement",
            WAKE_TABLE_SQL.replace(" PRIMARY KEY AUTOINCREMENT", " PRIMARY KEY"),
        ),
        (
            "wrong cause type",
            WAKE_TABLE_SQL.replace("cause TEXT NOT NULL", "cause BLOB NOT NULL"),
        ),
        (
            "wrong payload default",
            WAKE_TABLE_SQL.replace("DEFAULT '{}'", "DEFAULT '[]'"),
        ),
        (
            "extra column",
            WAKE_TABLE_SQL.replace(
                "processed_at TEXT",
                "processed_at TEXT, sentinel TEXT NOT NULL DEFAULT 'preserve-me'",
            ),
        ),
    ] {
        assert_wake_table_shape_rejected(case, &sql).await;
    }
}

#[tokio::test]
async fn async_connect_refuses_malformed_wake_event_pending_index() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute_batch(
            "DROP INDEX task_board_orchestrator_wake_events_pending;
             CREATE UNIQUE INDEX task_board_orchestrator_wake_events_pending
             ON task_board_orchestrator_wake_events(sequence, processed_at)
             WHERE processed_at IS NULL;",
        )
        .expect("replace wake-event pending index");
    drop(sync_db);

    let error = AsyncDaemonDb::connect(&db_path)
        .await
        .expect_err("malformed wake-event index must fail closed");

    assert!(error.to_string().contains("wake_events_pending"));
    let conn = Connection::open(&db_path).expect("reopen incompatible database");
    let definition: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'index' AND name = 'task_board_orchestrator_wake_events_pending'",
            [],
            |row| row.get(0),
        )
        .expect("inspect preserved wake-event index");
    assert!(definition.contains("CREATE UNIQUE INDEX"));
    assert!(definition.contains("sequence, processed_at"));
}

async fn assert_wake_table_shape_rejected(case: &str, table_sql: &str) {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute_batch("DROP TABLE task_board_orchestrator_wake_events")
        .expect("drop canonical wake-event table");
    sync_db
        .connection()
        .execute_batch(table_sql)
        .unwrap_or_else(|error| panic!("create {case} fixture: {error}"));
    sync_db
        .connection()
        .execute(
            "INSERT INTO task_board_orchestrator_wake_events (
                 cause, payload_json, created_at
             ) VALUES ('ledger_changed', '{\"sentinel\":true}', '2026-07-17T12:00:00Z')",
            [],
        )
        .unwrap_or_else(|error| panic!("seed {case} fixture: {error}"));
    drop(sync_db);

    let error = AsyncDaemonDb::connect(&db_path)
        .await
        .expect_err("incompatible wake-event table must fail closed");
    assert!(
        error
            .to_string()
            .contains("incompatible task_board_orchestrator_wake_events schema"),
        "case {case}: {error}"
    );

    let conn = Connection::open(&db_path).expect("reopen incompatible database");
    let payload: String = conn
        .query_row(
            "SELECT payload_json FROM task_board_orchestrator_wake_events WHERE sequence = 1",
            [],
            |row| row.get(0),
        )
        .expect("read preserved wake-event sentinel");
    assert_eq!(payload, "{\"sentinel\":true}");
}
