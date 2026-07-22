//! Precursor-v43 remote-assignment ledger repair: recognizes a v43 ledger whose
//! remote-assignment table predates the no-run Start-failure receipt columns and
//! rebuilds it in place, preserving every existing column and row.

use rusqlite::{Transaction, TransactionBehavior};

use super::{
    ASSIGNMENT_TABLE, CliError, Connection, INDEX_DDL, db_error, expected_table_sql,
    require_complete_shape,
};

/// True when the remote-assignment table is v43-era (it carries the Start
/// receipt) but predates the no-run Start-failure receipt columns.
pub(super) fn assignment_is_prefailure(conn: &Connection) -> Result<bool, CliError> {
    Ok(assignment_has_column(conn, "executor_start_receipt_json")?
        && !assignment_has_column(conn, "executor_start_failure_receipt_json")?)
}

fn assignment_has_column(conn: &Connection, column: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM pragma_table_info('task_board_remote_assignments') WHERE name = ?1
         )",
        [column],
        |row| row.get::<_, bool>(0),
    )
    .map_err(|error| db_error(format!("inspect remote assignment columns: {error}")))
}

fn assignment_column_names(conn: &Connection) -> Result<Vec<String>, CliError> {
    let mut statement = conn
        .prepare(
            "SELECT name FROM pragma_table_info('task_board_remote_assignments') ORDER BY cid",
        )
        .map_err(|error| db_error(format!("read remote assignment columns: {error}")))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| db_error(format!("read remote assignment columns: {error}")))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("collect remote assignment columns: {error}")))?;
    Ok(names)
}

/// Rebuilds a precursor-v43 remote-assignment table at the current shape (adding
/// the no-run Start-failure receipt columns NULL) while preserving every existing
/// column and row.
///
/// The swap renames and drops a table that five child tables reference by foreign
/// key. `legacy_alter_table` keeps the RENAME from repointing those references
/// onto the temp table, and suspended `foreign_keys` keeps the temp DROP from
/// cascading the children away. Both are no-ops inside a transaction, so they are
/// toggled around one here and always restored.
pub(super) fn rebuild_prefailure_receipt_assignment(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch("PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON")
        .map_err(|error| {
            db_error(format!("suspend foreign keys for precursor rebuild: {error}"))
        })?;
    let rebuilt = rebuild_within_suspended_foreign_keys(conn);
    let restored = conn
        .execute_batch("PRAGMA legacy_alter_table = OFF; PRAGMA foreign_keys = ON")
        .map_err(|error| {
            db_error(format!("restore foreign keys after precursor rebuild: {error}"))
        });
    rebuilt.and(restored)
}

fn rebuild_within_suspended_foreign_keys(conn: &Connection) -> Result<(), CliError> {
    let transaction = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)
        .map_err(|error| db_error(format!("begin precursor remote assignment rebuild: {error}")))?;
    let column_list = assignment_column_names(&transaction)?.join(", ");
    let create_sql = expected_table_sql(ASSIGNMENT_TABLE)?;
    transaction
        .execute_batch(&format!(
            "ALTER TABLE task_board_remote_assignments
                 RENAME TO task_board_remote_assignments_prefailure_receipt;
             {create_sql};
             INSERT INTO task_board_remote_assignments ({column_list})
                 SELECT {column_list} FROM task_board_remote_assignments_prefailure_receipt;
             DROP TABLE task_board_remote_assignments_prefailure_receipt;"
        ))
        .map_err(|error| db_error(format!("rebuild precursor remote assignment ledger: {error}")))?;
    transaction
        .execute_batch(INDEX_DDL)
        .map_err(|error| db_error(format!("restore remote execution indexes: {error}")))?;
    assert_no_foreign_key_violations(&transaction)?;
    require_complete_shape(&transaction)?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit precursor remote assignment rebuild: {error}")))
}

/// The rebuild ran with enforcement suspended, so verify no child row was
/// orphaned before committing the swap.
fn assert_no_foreign_key_violations(conn: &Connection) -> Result<(), CliError> {
    let mut statement = conn
        .prepare("PRAGMA foreign_key_check")
        .map_err(|error| db_error(format!("prepare precursor foreign key check: {error}")))?;
    let mut rows = statement
        .query([])
        .map_err(|error| db_error(format!("run precursor foreign key check: {error}")))?;
    let has_violation = rows
        .next()
        .map_err(|error| db_error(format!("read precursor foreign key check: {error}")))?
        .is_some();
    if has_violation {
        return Err(db_error(
            "precursor remote assignment rebuild left foreign key violations",
        ));
    }
    Ok(())
}
