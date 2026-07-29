use rusqlite::Connection;

use super::{CliError, db_error};

const ALTER_STATEMENTS: &[&str] = &[
    "ALTER TABLE agents ADD COLUMN managed_agent_kind TEXT",
    "ALTER TABLE agents ADD COLUMN managed_agent_id TEXT",
];

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if agents_table_exists(conn)? {
        for statement in ALTER_STATEMENTS {
            if let Err(error) = conn.execute(statement, []) {
                let message = error.to_string();
                if !message.contains("duplicate column name") {
                    return Err(db_error(format!(
                        "migrate v10 -> v11 ({statement}): {error}"
                    )));
                }
            }
        }
    }
    conn.execute(
        "UPDATE schema_meta SET value = '11' WHERE key = 'version'",
        [],
    )
    .map_err(|error| db_error(format!("bump schema version to v11: {error}")))?;
    Ok(())
}

fn agents_table_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agents'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check agents table existence: {error}")))
}
