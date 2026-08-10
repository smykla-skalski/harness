use super::*;

#[test]
fn upgrade_indexes_exact_progress_intent_identity_and_replays() {
    let conn = Connection::open_in_memory().expect("open database");
    conn.execute_batch(
        "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
         INSERT INTO schema_meta VALUES ('version', '70');
         CREATE TABLE task_board_dispatch_intents (
             intent_id TEXT PRIMARY KEY,
             item_id TEXT NOT NULL,
             work_item_id TEXT,
             status TEXT NOT NULL
         ) WITHOUT ROWID;",
    )
    .expect("seed v70 database");

    run(&conn).expect("upgrade v70 database");
    run(&conn).expect("replay upgraded database");

    let version: String = conn
        .query_row(
            "SELECT value FROM schema_meta WHERE key = 'version'",
            [],
            |row| row.get(0),
        )
        .expect("load schema version");
    assert_eq!(version, "71");
    let sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'index'
               AND name = 'idx_task_board_dispatch_intents_recovery'",
            [],
            |row| row.get(0),
        )
        .expect("load recovery index");
    assert!(sql.contains("item_id, work_item_id, status"));
}
