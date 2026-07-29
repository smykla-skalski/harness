use rusqlite::Connection;

use super::{CliError, db_error};

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    // The forward sqlx migrator runs the raw migration against a database that
    // already holds `codex_runs`. The sync chain, by contrast, can migrate a
    // synthetic legacy fixture that never created that table, so each column add
    // skips a missing table and tolerates an already-applied column.
    for column in ["task_id", "board_item_id", "workflow_execution_id"] {
        add_codex_run_column_if_missing(conn, column)?;
    }
    stamp_schema_version(conn)
}

fn add_codex_run_column_if_missing(conn: &Connection, column_name: &str) -> Result<(), CliError> {
    if !table_exists(conn, "codex_runs")? {
        return Ok(());
    }
    let sql = format!("ALTER TABLE codex_runs ADD COLUMN {column_name} TEXT");
    match conn.execute(&sql, []) {
        Ok(_) => Ok(()),
        Err(_) if column_exists(conn, "codex_runs", column_name)? => Ok(()),
        Err(error) => Err(db_error(format!(
            "add codex task binding column {column_name}: {error}"
        ))),
    }
}

fn table_exists(conn: &Connection, table_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check table {table_name}: {error}")))
}

fn column_exists(conn: &Connection, table_name: &str, column_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table_name, column_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table_name}.{column_name}: {error}")))
}

fn stamp_schema_version(conn: &Connection) -> Result<(), CliError> {
    conn.execute(
        "UPDATE schema_meta SET value = '32' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v32: {error}")))
}
