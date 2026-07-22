use super::tests::{insert_strict_assignment, legacy_v40_fixture, strict_request};
use super::*;
use crate::daemon::db::DaemonDb;

const DIGEST: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const EXECUTION_DIGEST: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const NOW: &str = "2026-07-19T10:00:00Z";

#[test]
fn controller_handoff_columns_are_complete_and_legacy_rows_are_unmarked() {
    let db = strict_handoff_db();
    let handoff_columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_assignments')
             WHERE name IN (
                 'controller_handoff_kind',
                 'controller_handoff_execution_sha256',
                 'controller_handoff_successor_assignment_id',
                 'controller_handoff_successor_fencing_epoch',
                 'controller_handoff_at'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect controller handoff columns");
    assert_eq!(handoff_columns, 5);
    let migrated_handoff_rows: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM task_board_remote_assignments
             WHERE legacy_migrated = 1
               AND (
                   controller_handoff_kind IS NOT NULL
                   OR controller_handoff_execution_sha256 IS NOT NULL
                   OR controller_handoff_successor_assignment_id IS NOT NULL
                   OR controller_handoff_successor_fencing_epoch IS NOT NULL
                   OR controller_handoff_at IS NOT NULL
               )",
            [],
            |row| row.get(0),
        )
        .expect("inspect migrated handoff evidence");
    assert_eq!(migrated_handoff_rows, 0);
}

#[test]
fn local_fallback_handoff_is_paired_and_terminal_state_bound() {
    let db = strict_handoff_db();
    insert_handoff_assignment(&db, "fallback-assignment", 3);
    let partial = db.connection().execute(
        "UPDATE task_board_remote_assignments
         SET controller_handoff_kind = 'local_fallback'
         WHERE assignment_id = 'fallback-assignment'",
        [],
    );
    assert_check_failure(partial, "partial handoff marker");
    let active = db.connection().execute(
        "UPDATE task_board_remote_assignments
         SET controller_handoff_kind = 'local_fallback',
             controller_handoff_execution_sha256 = ?1,
             controller_handoff_at = ?2
         WHERE assignment_id = 'fallback-assignment'",
        rusqlite::params![EXECUTION_DIGEST, NOW],
    );
    assert_check_failure(active, "active assignment handoff");

    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'superseded', completed_at = ?1,
                 controller_handoff_kind = 'local_fallback',
                 controller_handoff_execution_sha256 = ?2,
                 controller_handoff_at = ?1
             WHERE assignment_id = 'fallback-assignment'",
            rusqlite::params![NOW, EXECUTION_DIGEST],
        )
        .expect("persist exact local fallback handoff");
    let marker: (String, String, String) = db
        .connection()
        .query_row(
            "SELECT controller_handoff_kind,
                    controller_handoff_execution_sha256,
                    controller_handoff_at
             FROM task_board_remote_assignments
             WHERE assignment_id = 'fallback-assignment'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("load exact local fallback marker");
    assert_eq!(
        marker,
        ("local_fallback".into(), EXECUTION_DIGEST.into(), NOW.into())
    );
}

#[test]
fn reassignment_and_cleanup_handoffs_require_their_exact_evidence_shape() {
    let db = strict_handoff_db();
    insert_handoff_assignment(&db, "reassigned-assignment", 3);
    let partial_successor = db.connection().execute(
        "UPDATE task_board_remote_assignments
         SET state = 'superseded', completed_at = ?1,
             controller_handoff_kind = 'remote_reassigned',
             controller_handoff_execution_sha256 = ?2,
             controller_handoff_successor_assignment_id = 'successor-assignment',
             controller_handoff_at = ?1
         WHERE assignment_id = 'reassigned-assignment'",
        rusqlite::params![NOW, EXECUTION_DIGEST],
    );
    assert_check_failure(partial_successor, "partial successor handoff");
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'superseded', completed_at = ?1,
                 controller_handoff_kind = 'remote_reassigned',
                 controller_handoff_execution_sha256 = ?2,
                 controller_handoff_successor_assignment_id = 'successor-assignment',
                 controller_handoff_successor_fencing_epoch = 4,
                 controller_handoff_at = ?1
             WHERE assignment_id = 'reassigned-assignment'",
            rusqlite::params![NOW, EXECUTION_DIGEST],
        )
        .expect("persist exact reassignment handoff shape");

    insert_handoff_assignment(&db, "cleanup-assignment", 5);
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
         SET state = 'cancelled', completed_at = ?1,
             controller_handoff_kind = 'terminal_cleanup',
             controller_handoff_execution_sha256 = ?2,
             controller_handoff_at = ?1
         WHERE assignment_id = 'cleanup-assignment'",
            rusqlite::params![NOW, EXECUTION_DIGEST],
        )
        .expect("persist pending terminal cleanup handoff shape");
    let partial_cleanup = db.connection().execute(
        "UPDATE task_board_remote_assignments
         SET cleanup_settlement_request_sha256 = ?1
         WHERE assignment_id = 'cleanup-assignment'",
        rusqlite::params![DIGEST],
    );
    assert_check_failure(partial_cleanup, "partial cleanup completion evidence");
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'cancelled', completed_at = ?1,
                 cleanup_settlement_request_sha256 = ?2,
                 cleanup_completed_at = ?1,
                 controller_handoff_kind = 'terminal_cleanup',
                 controller_handoff_execution_sha256 = ?3,
                 controller_handoff_at = ?1
             WHERE assignment_id = 'cleanup-assignment'",
            rusqlite::params![NOW, DIGEST, EXECUTION_DIGEST],
        )
        .expect("persist exact terminal cleanup handoff shape");
}

fn strict_handoff_db() -> DaemonDb {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    db
}

fn insert_handoff_assignment(db: &DaemonDb, assignment_id: &str, epoch: i64) {
    // Each handoff assignment needs a distinct sealed request digest so the
    // canonical unique index on request_sha256 accepts every row instead of
    // rejecting the second as a collision on one shared digest.
    let request_digest = format!("{epoch:064x}");
    let request = strict_request(assignment_id, "execution-a", epoch, &request_digest);
    insert_strict_assignment(db.connection(), assignment_id, epoch, &request)
        .expect("insert strict handoff assignment");
}

fn assert_check_failure(result: rusqlite::Result<usize>, context: &str) {
    assert!(
        result
            .expect_err(context)
            .to_string()
            .contains("CHECK constraint failed")
    );
}
