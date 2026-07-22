use rusqlite::{OptionalExtension, Transaction, TransactionBehavior};

use super::{CliError, Connection, db_error};

const TABLE_NAME: &str = "task_board_reconciliation_cursors";
const MIGRATION_SQL: &str =
    include_str!("migrations/0034_daemon_v40_task_board_reconciliation_cursors.sql");
const EXPECTED_TABLE_SQL: &str = "
CREATE TABLE task_board_reconciliation_cursors (
    queue TEXT PRIMARY KEY,
    sort_updated_at TEXT NOT NULL,
    sort_execution_id TEXT NOT NULL
) WITHOUT ROWID";

pub(super) fn shape_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    let Some(stored_sql) = table_sql(conn)? else {
        return Ok(true);
    };
    require_expected_shape(&stored_sql)?;
    Ok(false)
}

pub(super) fn repair_and_stamp(conn: &Connection) -> Result<(), CliError> {
    let transaction =
        Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(|error| {
            db_error(format!(
                "begin task-board reconciliation cursor repair: {error}"
            ))
        })?;
    if let Some(stored_sql) = table_sql(&transaction)? {
        require_expected_shape(&stored_sql)?;
    }
    transaction.execute_batch(MIGRATION_SQL).map_err(|error| {
        db_error(format!(
            "create task-board reconciliation cursor schema: {error}"
        ))
    })?;
    require_complete_shape(&transaction)?;
    transaction.commit().map_err(|error| {
        db_error(format!(
            "commit task-board reconciliation cursor repair: {error}"
        ))
    })
}

pub(super) fn require_complete_shape(conn: &Connection) -> Result<(), CliError> {
    let stored_sql = table_sql(conn)?
        .ok_or_else(|| db_error("missing task-board reconciliation cursor table"))?;
    require_expected_shape(&stored_sql)
}

fn table_sql(conn: &Connection) -> Result<Option<String>, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [TABLE_NAME],
        |row| row.get(0),
    )
    .optional()
    .map_err(|error| {
        db_error(format!(
            "read task-board reconciliation cursor schema: {error}"
        ))
    })
}

fn require_expected_shape(stored_sql: &str) -> Result<(), CliError> {
    if normalize_sql(stored_sql) == normalize_sql(EXPECTED_TABLE_SQL) {
        return Ok(());
    }
    Err(db_error(
        "incompatible task-board reconciliation cursor schema; refusing destructive repair",
    ))
}

fn normalize_sql(sql: &str) -> String {
    super::schema_repairs::normalize_schema_sql(sql)
}
