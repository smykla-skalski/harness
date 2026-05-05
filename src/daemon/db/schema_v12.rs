use rusqlite::Connection;

use super::{CliError, db_error};

const ALTER_STATEMENTS: &[&str] = &["ALTER TABLE tasks ADD COLUMN deleted_at TEXT"];

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if tasks_table_exists(conn)? {
        for statement in ALTER_STATEMENTS {
            if let Err(error) = conn.execute(statement, []) {
                let message = error.to_string();
                if !message.contains("duplicate column name") {
                    return Err(db_error(format!(
                        "migrate v11 -> v12 ({statement}): {error}"
                    )));
                }
            }
        }
    }
    conn.execute(
        "UPDATE schema_meta SET value = '12' WHERE key = 'version'",
        [],
    )
    .map_err(|error| db_error(format!("bump schema version to v12: {error}")))?;
    Ok(())
}

fn tasks_table_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='tasks'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check tasks table existence: {error}")))
}
