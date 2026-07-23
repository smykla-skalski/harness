use super::*;
use crate::daemon::db::{DaemonDb, SCHEMA_VERSION};

const CONTROLLER_SCAN_INDEX: &str = "task_board_remote_assignments_controller_scan";
const SETTLEMENT_RECEIPT_DELETE_GUARD: &str =
    "task_board_remote_assignments_preserve_settlement_receipts";

#[test]
fn fresh_schema_has_remote_execution_integrity_objects() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    assert_eq!(db.schema_version().expect("schema version"), SCHEMA_VERSION);

    let scan_columns: String = db
        .connection()
        .query_row(
            "SELECT group_concat(name, ',') FROM (
               SELECT name FROM pragma_index_info(?1) ORDER BY seqno
             )",
            [CONTROLLER_SCAN_INDEX],
            |row| row.get(0),
        )
        .expect("read controller scan index columns");
    assert_eq!(scan_columns, "offered_at,assignment_id");

    let trigger_sql: String = db
        .connection()
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1",
            [SETTLEMENT_RECEIPT_DELETE_GUARD],
            |row| row.get(0),
        )
        .expect("read immutable receipt delete guard");
    assert!(trigger_sql.contains("BEFORE DELETE ON task_board_remote_assignments"));
    assert!(trigger_sql.contains("immutable settlement receipt"));
}

#[test]
fn repair_restores_missing_objects_and_refuses_trigger_drift() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    db.connection()
        .execute_batch(
            "DROP INDEX task_board_remote_assignments_controller_scan;
             DROP TRIGGER task_board_remote_assignments_preserve_settlement_receipts;",
        )
        .expect("remove v45 integrity objects");

    run(db.connection()).expect("repair v45 integrity objects");
    assert_eq!(object_count(&db, "index", CONTROLLER_SCAN_INDEX), 1);
    assert_eq!(
        object_count(&db, "trigger", SETTLEMENT_RECEIPT_DELETE_GUARD),
        1
    );

    db.connection()
        .execute_batch(
            "DROP TRIGGER task_board_remote_assignments_preserve_settlement_receipts;
             CREATE TRIGGER task_board_remote_assignments_preserve_settlement_receipts
             BEFORE DELETE ON task_board_remote_assignments
             BEGIN
                 SELECT 1;
             END;",
        )
        .expect("replace delete guard with drifted trigger");
    let error = run(db.connection()).expect_err("trigger drift must fail closed");
    assert!(
        error
            .to_string()
            .contains("incompatible remote execution v45 trigger")
    );
}

fn object_count(db: &DaemonDb, object_type: &str, name: &str) -> i64 {
    db.connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = ?1 AND name = ?2",
            [object_type, name],
            |row| row.get(0),
        )
        .expect("count schema object")
}
