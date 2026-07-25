use rusqlite::{Connection, Transaction, TransactionBehavior};

use super::CliError;

const REMOVE_TODOIST_SQL: &str = include_str!("migrations/0052_daemon_v54_task_board_remove_todoist.sql");
const PROJECTS_SOURCE_SQL: &str =
    include_str!("migrations/0053_daemon_v54_task_board_projects_source.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let transaction = conn
        .unchecked_transaction()
        .map_err(|error| super::db_error(format!("begin schema v54 cleanup: {error}")))?;
    transaction
        .execute_batch(REMOVE_TODOIST_SQL)
        .map_err(|error| super::db_error(format!("apply schema v54 cleanup: {error}")))?;
    transaction
        .commit()
        .map_err(|error| super::db_error(format!("commit schema v54 cleanup: {error}")))?;
    // The repair chain replays every step unconditionally, and the rebuild is
    // not expressible as an idempotent statement, so it is guarded on the
    // constraint it exists to change.
    if projects_source_accepts_todoist(conn)? {
        rebuild_projects_source(conn)?;
    }
    conn.execute(
        "UPDATE schema_meta SET value = '54' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| super::db_error(format!("stamp schema v54: {error}")))
}

fn projects_source_accepts_todoist(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM sqlite_master
           WHERE type = 'table' AND name = 'task_board_projects' AND sql LIKE '%todoist%'
         )",
        [],
        |row| row.get::<_, bool>(0),
    )
    .map_err(|error| super::db_error(format!("inspect task_board_projects source check: {error}")))
}

/// The swap drops and renames a table `task_board_items` references by foreign
/// key. `legacy_alter_table` keeps the RENAME from repointing that reference
/// onto the temp table, and suspended `foreign_keys` keeps the temp DROP from
/// cascading. Both are no-ops inside a transaction, so they are toggled around
/// one here and always restored.
fn rebuild_projects_source(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch("PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON")
        .map_err(|error| {
            super::db_error(format!("suspend foreign keys for schema v54: {error}"))
        })?;
    let rebuilt = rebuild_within_suspended_foreign_keys(conn);
    let restored = conn
        .execute_batch("PRAGMA legacy_alter_table = OFF; PRAGMA foreign_keys = ON")
        .map_err(|error| {
            super::db_error(format!("restore foreign keys after schema v54: {error}"))
        });
    rebuilt.and(restored)
}

fn rebuild_within_suspended_foreign_keys(conn: &Connection) -> Result<(), CliError> {
    let transaction = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)
        .map_err(|error| super::db_error(format!("begin schema v54 projects rebuild: {error}")))?;
    transaction
        .execute_batch(PROJECTS_SOURCE_SQL)
        .map_err(|error| super::db_error(format!("rebuild schema v54 projects: {error}")))?;
    assert_no_foreign_key_violations(&transaction)?;
    transaction
        .commit()
        .map_err(|error| super::db_error(format!("commit schema v54 projects rebuild: {error}")))
}

/// The rebuild ran with enforcement suspended, so verify no item was left
/// pointing at a project the swap dropped before committing it.
fn assert_no_foreign_key_violations(conn: &Connection) -> Result<(), CliError> {
    let violations: i64 = conn
        .query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
            row.get(0)
        })
        .map_err(|error| super::db_error(format!("check schema v54 foreign keys: {error}")))?;
    if violations > 0 {
        return Err(super::db_error(format!(
            "schema v54 projects rebuild left {violations} foreign key violations"
        )));
    }
    Ok(())
}

#[cfg(test)]
#[path = "schema_v54_tests.rs"]
mod tests;
