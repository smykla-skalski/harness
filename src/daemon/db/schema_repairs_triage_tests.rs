use tempfile::tempdir;

use super::shape_needs_repair;
use crate::daemon::db::DaemonDb;

#[test]
fn fresh_v48_database_reopens_without_a_shape_repair_error() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open fresh database");
    drop(db);

    let reopened = DaemonDb::open(&path).expect("reopen v48 database");
    assert!(!shape_needs_repair(reopened.connection()).expect("shape check"));
}

#[test]
fn a_genuinely_corrupt_triage_decisions_shape_is_still_rejected() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open fresh database");
    db.connection()
        .execute_batch(
            "ALTER TABLE task_board_triage_decisions RENAME TO task_board_triage_decisions_shadow;
             CREATE TABLE task_board_triage_decisions (decision_id TEXT PRIMARY KEY);",
        )
        .expect("corrupt the triage decisions shape");

    let error = shape_needs_repair(db.connection()).expect_err("corrupt shape must be rejected");
    assert!(format!("{error}").contains("refusing destructive repair"));
}
