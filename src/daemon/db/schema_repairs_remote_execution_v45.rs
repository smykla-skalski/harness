use rusqlite::{OptionalExtension, Transaction, TransactionBehavior};

use super::{CliError, Connection, db_error, schema_repairs_remote_execution_objects as objects};

const MIGRATION_SQL: &str =
    include_str!("migrations/0039_daemon_v45_task_board_remote_execution_integrity.sql");
const CONTROLLER_SCAN_INDEX: &str = "task_board_remote_assignments_controller_scan";
const SETTLEMENT_RECEIPT_DELETE_GUARD: &str =
    "task_board_remote_assignments_preserve_settlement_receipts";
const REPAIR_DDL: &str = "
CREATE INDEX IF NOT EXISTS task_board_remote_assignments_controller_scan
    ON task_board_remote_assignments(offered_at, assignment_id);
CREATE TRIGGER IF NOT EXISTS task_board_remote_assignments_preserve_settlement_receipts
BEFORE DELETE ON task_board_remote_assignments
WHEN EXISTS (
    SELECT 1
    FROM task_board_remote_settlement_receipts
    WHERE assignment_id = OLD.assignment_id
      AND fencing_epoch = OLD.fencing_epoch
)
BEGIN
    SELECT RAISE(ABORT, 'cannot delete remote assignment with immutable settlement receipt');
END;
";

pub(super) fn shape_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    let missing_index = index_needs_repair(conn)?;
    let missing_trigger = trigger_needs_repair(conn)?;
    Ok(missing_index || missing_trigger)
}

pub(super) fn repair_and_stamp(conn: &Connection) -> Result<(), CliError> {
    super::schema_repairs_remote_execution::require_complete_shape(conn)?;
    let transaction = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)
        .map_err(|error| db_error(format!("begin remote execution v45 repair: {error}")))?;
    if shape_needs_repair(&transaction)? {
        transaction
            .execute_batch(REPAIR_DDL)
            .map_err(|error| db_error(format!("repair remote execution v45 schema: {error}")))?;
    }
    require_complete_shape(&transaction)?;
    transaction
        .execute(
            "UPDATE schema_meta SET value = '45' WHERE key = 'version'",
            [],
        )
        .map_err(|error| db_error(format!("stamp remote execution v45 schema: {error}")))?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit remote execution v45 repair: {error}")))
}

pub(super) fn require_complete_shape(conn: &Connection) -> Result<(), CliError> {
    super::schema_repairs_remote_execution::require_complete_shape(conn)?;
    if shape_needs_repair(conn)? {
        return Err(db_error(
            "remote execution v45 repair left required schema objects missing",
        ));
    }
    Ok(())
}

fn index_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    let expected = objects::expected_index_sql(MIGRATION_SQL, CONTROLLER_SCAN_INDEX)?;
    object_needs_repair(conn, "index", CONTROLLER_SCAN_INDEX, &expected)
}

fn trigger_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    let expected = objects::expected_trigger_sql(MIGRATION_SQL, SETTLEMENT_RECEIPT_DELETE_GUARD)?;
    object_needs_repair(conn, "trigger", SETTLEMENT_RECEIPT_DELETE_GUARD, &expected)
}

fn object_needs_repair(
    conn: &Connection,
    object_type: &str,
    name: &str,
    expected: &str,
) -> Result<bool, CliError> {
    let Some(actual) = object_sql(conn, object_type, name)? else {
        return Ok(true);
    };
    if normalize_sql(&actual) == expected {
        return Ok(false);
    }
    Err(db_error(format!(
        "incompatible remote execution v45 {object_type} '{name}'; refusing destructive repair"
    )))
}

fn object_sql(
    conn: &Connection,
    object_type: &str,
    name: &str,
) -> Result<Option<String>, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = ?1 AND name = ?2",
        [object_type, name],
        |row| row.get(0),
    )
    .optional()
    .map_err(|error| {
        db_error(format!(
            "read remote execution v45 {object_type} {name}: {error}"
        ))
    })
}

fn normalize_sql(sql: &str) -> String {
    super::schema_repairs::normalize_schema_sql(sql)
}
