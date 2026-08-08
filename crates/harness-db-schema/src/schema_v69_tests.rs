use super::*;

const SEED_V68_SQL: &str = "PRAGMA foreign_keys = ON;
     CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
     INSERT INTO schema_meta VALUES ('version', '68');
     CREATE TABLE task_board_items (
         item_id       TEXT PRIMARY KEY,
         status        TEXT NOT NULL,
         workflow_json TEXT NOT NULL,
         work_item_id  TEXT,
         revision      INTEGER NOT NULL DEFAULT 1,
         created_at    TEXT NOT NULL,
         updated_at    TEXT NOT NULL,
         deleted_at    TEXT
     );";

fn seeded_connection() -> Connection {
    let conn = Connection::open_in_memory().expect("open database");
    conn.execute_batch(SEED_V68_SQL).expect("seed v68 database");
    conn
}

fn insert_item(conn: &Connection, item_id: &str, status: &str, workflow: &str, work_item: &str) {
    conn.execute(
        "INSERT INTO task_board_items (
             item_id, status, workflow_json, work_item_id, revision, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, 4, '2026-08-01T00:00:00Z', '2026-08-02T00:00:00Z')",
        rusqlite::params![item_id, status, workflow, work_item],
    )
    .expect("insert task-board item");
}

fn backfilled_state(conn: &Connection, work_item_id: &str) -> String {
    conn.query_row(
        "SELECT state FROM task_board_work_item_progress WHERE work_item_id = ?1",
        [work_item_id],
        |row| row.get(0),
    )
    .expect("load backfilled state")
}

#[test]
fn upgrade_backfills_every_dispatched_lane_and_replays() {
    let conn = seeded_connection();
    insert_item(&conn, "item-1", "in_progress", "{}", "work-1");
    insert_item(
        &conn,
        "item-2",
        "in_progress",
        r#"{"current_step_id":"awaiting_delivery"}"#,
        "work-2",
    );
    insert_item(&conn, "item-3", "to_review", "{}", "work-3");
    insert_item(&conn, "item-4", "in_review", "{}", "work-4");
    insert_item(&conn, "item-5", "done", "{}", "work-5");
    insert_item(
        &conn,
        "item-6",
        "failed",
        r#"{"last_error":"worktree unchanged"}"#,
        "work-6",
    );
    insert_item(&conn, "item-7", "todo", "{}", "work-7");

    run(&conn).expect("upgrade v68 database");
    run(&conn).expect("replay upgraded database");

    assert_eq!(backfilled_state(&conn, "work-1"), "running");
    assert_eq!(backfilled_state(&conn, "work-2"), "pending");
    assert_eq!(backfilled_state(&conn, "work-3"), "awaiting_review");
    assert_eq!(backfilled_state(&conn, "work-4"), "in_review");
    assert_eq!(backfilled_state(&conn, "work-5"), "done");
    assert_eq!(backfilled_state(&conn, "work-6"), "blocked");
    assert_eq!(backfilled_state(&conn, "work-7"), "pending");
    let version: String = conn
        .query_row(
            "SELECT value FROM schema_meta WHERE key = 'version'",
            [],
            |row| row.get(0),
        )
        .expect("load schema version");
    assert_eq!(version, "69");
}

#[test]
fn backfill_carries_execution_binding_revision_and_block_reason() {
    let conn = seeded_connection();
    insert_item(
        &conn,
        "item-1",
        "failed",
        r#"{"execution_id":"workflow-1","last_error":"no completion evidence"}"#,
        "work-1",
    );

    run(&conn).expect("upgrade v68 database");

    let row: (String, i64, String, String) = conn
        .query_row(
            "SELECT execution_id, item_revision, blocked_reason, completed_at
             FROM task_board_work_item_progress WHERE work_item_id = 'work-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .expect("load backfilled record");
    assert_eq!(
        row,
        (
            "workflow-1".into(),
            4,
            "no completion evidence".into(),
            "2026-08-02T00:00:00Z".into()
        )
    );
}

#[test]
fn backfill_skips_undispatched_and_deleted_items() {
    let conn = seeded_connection();
    conn.execute(
        "INSERT INTO task_board_items (
             item_id, status, workflow_json, work_item_id, revision, created_at, updated_at
         ) VALUES ('item-1', 'todo', '{}', NULL, 1, 'created', 'updated')",
        [],
    )
    .expect("insert undispatched item");
    conn.execute(
        "INSERT INTO task_board_items (
             item_id, status, workflow_json, work_item_id, revision,
             created_at, updated_at, deleted_at
         ) VALUES ('item-2', 'done', '{}', 'work-2', 1, 'created', 'updated', 'deleted')",
        [],
    )
    .expect("insert deleted item");

    run(&conn).expect("upgrade v68 database");

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM task_board_work_item_progress",
            [],
            |row| row.get(0),
        )
        .expect("count backfilled records");
    assert_eq!(count, 0);
}

#[test]
fn replay_never_overwrites_progress_a_worker_already_moved() {
    let conn = seeded_connection();
    insert_item(&conn, "item-1", "in_progress", "{}", "work-1");
    run(&conn).expect("upgrade v68 database");
    conn.execute(
        "UPDATE task_board_work_item_progress
         SET state = 'awaiting_review', report_sequence = 3 WHERE work_item_id = 'work-1'",
        [],
    )
    .expect("advance the record");

    run(&conn).expect("replay upgraded database");

    let row: (String, i64) = conn
        .query_row(
            "SELECT state, report_sequence FROM task_board_work_item_progress
             WHERE work_item_id = 'work-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load record after replay");
    assert_eq!(row, ("awaiting_review".into(), 3));
}

#[test]
fn settled_records_must_carry_a_settlement_time() {
    let conn = seeded_connection();
    insert_item(&conn, "item-1", "in_progress", "{}", "work-1");
    run(&conn).expect("upgrade v68 database");

    let refused = conn.execute(
        "UPDATE task_board_work_item_progress SET state = 'done' WHERE work_item_id = 'work-1'",
        [],
    );

    assert!(refused.is_err(), "settling without a time must be refused");
}

#[test]
fn checkpoints_cascade_with_their_work_item() {
    let conn = seeded_connection();
    insert_item(&conn, "item-1", "in_progress", "{}", "work-1");
    run(&conn).expect("upgrade v68 database");
    conn.execute(
        "INSERT INTO task_board_work_item_checkpoints (
             work_item_id, sequence, checkpoint_id, actor, summary, recorded_at
         ) VALUES ('work-1', 1, 'checkpoint-1', 'agent-1', 'first', 'recorded')",
        [],
    )
    .expect("insert checkpoint");

    conn.execute("DELETE FROM task_board_items WHERE item_id = 'item-1'", [])
        .expect("delete the owning item");

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM task_board_work_item_checkpoints",
            [],
            |row| row.get(0),
        )
        .expect("count checkpoints");
    assert_eq!(count, 0);
}
