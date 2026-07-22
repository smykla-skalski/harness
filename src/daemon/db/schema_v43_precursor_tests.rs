use super::tests::{insert_strict_assignment, legacy_v40_fixture, strict_request};
use super::*;

// The precursor-v43 shape is the current ledger minus the two Start-failure
// receipt columns and every CHECK that references them. Derived structurally from
// the live table so it survives edits to the failure-receipt CHECK text.
fn install_precursor_assignment_shape(conn: &Connection) {
    let current_sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'table' AND name = 'task_board_remote_assignments'",
            [],
            |row| row.get(0),
        )
        .expect("read live assignment DDL");
    let precursor_sql = derive_precursor_sql(&current_sql);
    assert!(
        !precursor_sql.contains("executor_start_failure_receipt"),
        "fixture must strip both failure-receipt columns and their CHECKs"
    );
    // The table is empty here, so drop and recreate at the precursor shape. The
    // identity/epoch unique index backs the child foreign keys and lives outside
    // the CREATE TABLE text, so recreate it or the child seed fails to reference.
    conn.execute_batch(&format!(
        "DROP TABLE task_board_remote_assignments;
         {precursor_sql};
         CREATE UNIQUE INDEX task_board_remote_assignments_identity_epoch
             ON task_board_remote_assignments(assignment_id, fencing_epoch);"
    ))
    .expect("install precursor assignment shape");
}

/// Strips the two failure-receipt columns, the legacy branch's failure-receipt
/// NULL fragments, and every top-level `CHECK` clause that still references the
/// failure receipt. The legacy-preservation CHECK is kept: its fragments are
/// removed first, so by the time the CHECK-drop pass runs it no longer matches.
fn derive_precursor_sql(current_sql: &str) -> String {
    let without_columns: Vec<&str> = current_sql
        .lines()
        .filter(|line| {
            let trimmed = line.trim_start();
            !(trimmed.starts_with("executor_start_failure_receipt_json TEXT")
                || trimmed.starts_with("executor_start_failure_receipt_sha256 TEXT")
                || trimmed == "AND executor_start_failure_receipt_json IS NULL"
                || trimmed == "AND executor_start_failure_receipt_sha256 IS NULL")
        })
        .collect();
    let mut kept: Vec<&str> = Vec::new();
    let mut lines = without_columns.into_iter().peekable();
    while let Some(line) = lines.next() {
        if !line.trim_start().starts_with("CHECK (") {
            kept.push(line);
            continue;
        }
        let mut clause = vec![line];
        let mut depth = paren_delta(line);
        while depth > 0 {
            let Some(next) = lines.next() else { break };
            depth += paren_delta(next);
            clause.push(next);
        }
        if clause
            .iter()
            .any(|clause_line| clause_line.contains("executor_start_failure_receipt"))
        {
            continue;
        }
        kept.extend(clause);
    }
    kept.join("\n")
}

fn paren_delta(line: &str) -> i64 {
    line.matches('(').count() as i64 - line.matches(')').count() as i64
}

fn seed_child_recovery_quarantine(conn: &Connection) {
    conn.execute(
        "INSERT INTO task_board_remote_recovery_quarantine (
             assignment_id, fencing_epoch, assignment_state, assignment_updated_at,
             state_fingerprint, failure_count, next_attempt_at, last_error_code, updated_at
         ) VALUES (
             'assignment-a', 1, 'unknown', '2026-07-19T09:00:00Z',
             'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
             1, '2026-07-19T10:00:00Z', 'CODEX001', '2026-07-19T09:00:00Z'
         )",
        [],
    )
    .expect("seed child recovery-quarantine row");
}

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |row| row.get(0)).expect("count rows")
}

// A precursor-shape database with a real assignment and a child row must reopen
// cleanly: the in-place rebuild adds the failure-receipt columns NULL and
// preserves every assignment and child row. A rename that repointed the child
// foreign keys would cascade the child away and fail the shape check on reopen.
#[test]
fn precursor_v43_repair_preserves_assignment_and_child_rows() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate to current v43 shape");
    install_precursor_assignment_shape(db.connection());
    let request = strict_request(
        "assignment-a",
        "execution-a",
        1,
        "1111111111111111111111111111111111111111111111111111111111111111",
    );
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("seed precursor assignment");
    seed_child_recovery_quarantine(db.connection());

    assert_eq!(
        super::super::schema_repairs_remote_execution::classification_for_test(db.connection()),
        "PreFailureReceiptV43",
        "precursor fixture must classify as a repairable precursor before restart"
    );
    run(db.connection()).expect("repair the precursor-v43 shape on restart");

    assert_eq!(db.schema_version().expect("schema version"), "43");
    assert_eq!(
        count(
            db.connection(),
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_assignments')
             WHERE name IN (
                 'executor_start_failure_receipt_json', 'executor_start_failure_receipt_sha256'
             )",
        ),
        2,
        "the rebuild must add both failure-receipt columns"
    );
    assert_eq!(
        count(
            db.connection(),
            "SELECT COUNT(*) FROM task_board_remote_assignments WHERE assignment_id = 'assignment-a'
               AND executor_start_failure_receipt_json IS NULL
               AND executor_start_failure_receipt_sha256 IS NULL",
        ),
        1,
        "the assignment row must survive with the new columns NULL"
    );
    assert_eq!(
        count(
            db.connection(),
            "SELECT COUNT(*) FROM task_board_remote_recovery_quarantine
             WHERE assignment_id = 'assignment-a'",
        ),
        1,
        "child rows must survive the rebuild, not cascade away"
    );
}
