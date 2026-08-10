use super::*;

#[test]
fn upgrade_indexes_only_active_attempt_bearing_progress_and_replays() {
    let conn = Connection::open_in_memory().expect("open database");
    conn.execute_batch(
        "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
         INSERT INTO schema_meta VALUES ('version', '69');
         CREATE TABLE task_board_work_item_progress (
             item_id TEXT NOT NULL,
             work_item_id TEXT NOT NULL,
             state TEXT NOT NULL,
             attempt_id TEXT,
             completed_at TEXT,
             PRIMARY KEY (item_id, work_item_id)
         ) WITHOUT ROWID;",
    )
    .expect("seed v69 database");

    run(&conn).expect("upgrade v69 database");
    run(&conn).expect("replay upgraded database");

    let version: String = conn
        .query_row(
            "SELECT value FROM schema_meta WHERE key = 'version'",
            [],
            |row| row.get(0),
        )
        .expect("load schema version");
    assert_eq!(version, "70");
    let sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'index'
               AND name = 'idx_task_board_work_item_progress_recovery'",
            [],
            |row| row.get(0),
        )
        .expect("load recovery index");
    assert!(sql.contains("item_id, work_item_id, attempt_id"));
    assert!(sql.contains("completed_at IS NULL"));
    assert!(sql.contains("state IN ('pending', 'running')"));
    assert!(sql.contains("attempt_id IS NOT NULL"));
}
