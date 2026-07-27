use rusqlite::Connection;
use tempfile::tempdir;

use super::run;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

fn value(conn: &Connection, table: &str, column: &str, id: &str, id_value: &str) -> String {
    let query = format!("SELECT {column} FROM {table} WHERE {id} = ?1");
    conn.query_row(&query, [id_value], |row| row.get(0))
        .expect("stored value")
}

fn seeded() -> Connection {
    let conn = Connection::open_in_memory().expect("open memory db");
    conn.execute_batch(
        "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
         CREATE TABLE task_board_items (item_id TEXT PRIMARY KEY, status TEXT NOT NULL);
         CREATE TABLE task_board_external_refs (item_id TEXT PRIMARY KEY, sync_state_json TEXT);
         CREATE TABLE task_board_sync_conflicts (
             conflict_id TEXT PRIMARY KEY,
             field TEXT NOT NULL,
             base_value_json TEXT NOT NULL,
             local_value_json TEXT NOT NULL,
             remote_value_json TEXT NOT NULL
         );
         CREATE TABLE task_board_orchestrator_settings (
             singleton INTEGER PRIMARY KEY,
             settings_json TEXT NOT NULL
         );
         CREATE TABLE task_board_orchestrator_state (
             singleton INTEGER PRIMARY KEY,
             state_json TEXT NOT NULL
         );
         CREATE TABLE task_board_orchestrator_runs (
             run_id TEXT PRIMARY KEY,
             scope_json TEXT NOT NULL,
             stage_summary_json TEXT NOT NULL
         );
         CREATE TABLE task_board_dispatch_intents (
             intent_id TEXT PRIMARY KEY,
             payload_json TEXT NOT NULL
         );
         CREATE TABLE task_board_external_create_intents (
             intent_id TEXT PRIMARY KEY,
             create_snapshot_json TEXT NOT NULL,
             external_ref_json TEXT
         );
         CREATE TABLE audit_events (
             id TEXT PRIMARY KEY,
             kind TEXT NOT NULL,
             payload_json TEXT
         );
         INSERT INTO schema_meta VALUES ('version', '55');
         INSERT INTO task_board_items VALUES ('item', 'backlog');
         INSERT INTO task_board_external_refs VALUES ('item', '{\"status\":\"backlog\"}');
         INSERT INTO task_board_sync_conflicts VALUES ('conflict', 'status', '\"backlog\"', '\"backlog\"', '\"backlog\"');
         INSERT INTO task_board_orchestrator_settings VALUES (1, '{\"dispatch_status_filter\":\"backlog\"}');
         INSERT INTO task_board_orchestrator_state VALUES (1, '{\"status\":\"backlog\",\"label\":\"backlog\"}');
         INSERT INTO task_board_orchestrator_runs VALUES ('run', '{\"status\":\"backlog\"}', '{\"stages\":[{\"from_status\":\"backlog\",\"to_status\":\"backlog\"}]}');
         INSERT INTO task_board_dispatch_intents VALUES ('intent', '{\"board_status\":\"backlog\"}');
         INSERT INTO task_board_external_create_intents VALUES ('create', '{\"status\":\"backlog\"}', '{\"sync_state\":{\"status\":\"backlog\"}}');
         INSERT INTO audit_events VALUES ('task-board', 'task_board.item.updated', '{\"status\":\"backlog\"}');
         INSERT INTO audit_events VALUES ('other', 'session.updated', '{\"status\":\"backlog\"}');",
    )
    .expect("seed v55 task-board state");
    conn
}

#[test]
fn migrates_every_live_task_board_status_representation() {
    let conn = seeded();

    run(&conn).expect("run v56");

    assert_eq!(
        value(&conn, "task_board_items", "status", "item_id", "item"),
        "inbox"
    );
    assert_eq!(
        value(
            &conn,
            "task_board_external_refs",
            "sync_state_json",
            "item_id",
            "item"
        ),
        "{\"status\":\"inbox\"}"
    );
    assert_eq!(
        value(
            &conn,
            "task_board_sync_conflicts",
            "base_value_json",
            "conflict_id",
            "conflict"
        ),
        "\"inbox\""
    );
    assert_eq!(
        value(
            &conn,
            "task_board_sync_conflicts",
            "local_value_json",
            "conflict_id",
            "conflict"
        ),
        "\"inbox\""
    );
    assert_eq!(
        value(
            &conn,
            "task_board_sync_conflicts",
            "remote_value_json",
            "conflict_id",
            "conflict"
        ),
        "\"inbox\""
    );
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&value(
            &conn,
            "task_board_orchestrator_state",
            "state_json",
            "singleton",
            "1"
        ))
        .expect("state JSON")["status"],
        "inbox"
    );
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&value(
            &conn,
            "task_board_orchestrator_state",
            "state_json",
            "singleton",
            "1"
        ))
        .expect("state JSON")["label"],
        "backlog"
    );
    for (table, column, id, id_value) in [
        (
            "task_board_orchestrator_settings",
            "settings_json",
            "singleton",
            "1",
        ),
        (
            "task_board_orchestrator_runs",
            "scope_json",
            "run_id",
            "run",
        ),
        (
            "task_board_orchestrator_runs",
            "stage_summary_json",
            "run_id",
            "run",
        ),
        (
            "task_board_dispatch_intents",
            "payload_json",
            "intent_id",
            "intent",
        ),
        (
            "task_board_external_create_intents",
            "create_snapshot_json",
            "intent_id",
            "create",
        ),
        (
            "task_board_external_create_intents",
            "external_ref_json",
            "intent_id",
            "create",
        ),
        ("audit_events", "payload_json", "id", "task-board"),
    ] {
        assert!(
            !value(&conn, table, column, id, id_value).contains("backlog"),
            "{table}.{column} must be canonical"
        );
    }
    assert_eq!(
        value(&conn, "audit_events", "payload_json", "id", "other"),
        "{\"status\":\"backlog\"}"
    );
}

#[test]
fn migration_is_idempotent_and_stamps_the_new_version() {
    let conn = seeded();

    run(&conn).expect("first run v56");
    run(&conn).expect("second run v56");

    assert_eq!(
        conn.query_row(
            "SELECT value FROM schema_meta WHERE key = 'version'",
            [],
            |row| row.get::<_, String>(0)
        )
        .expect("schema version"),
        "56"
    );
}

#[tokio::test]
async fn async_upgrade_records_the_v56_migration() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v55 database");
    db.connection()
        .execute(
            "UPDATE schema_meta SET value = '55' WHERE key = 'version'",
            [],
        )
        .expect("restore v55 version");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v55 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}
