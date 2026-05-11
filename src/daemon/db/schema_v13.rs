use rusqlite::Connection;

use super::{CliError, db_error};

const ALTER_STATEMENTS: &[&str] = &[
    "ALTER TABLE codex_runs ADD COLUMN session_agent_id TEXT",
    "ALTER TABLE codex_runs ADD COLUMN display_name TEXT",
    "ALTER TABLE codex_runs ADD COLUMN model TEXT",
    "ALTER TABLE codex_runs ADD COLUMN effort TEXT",
    "ALTER TABLE codex_runs ADD COLUMN resolved_approvals_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE codex_runs ADD COLUMN events_json TEXT NOT NULL DEFAULT '[]'",
];

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if codex_runs_table_exists(conn)? {
        for statement in ALTER_STATEMENTS {
            if let Err(error) = conn.execute(statement, []) {
                let message = error.to_string();
                if !message.contains("duplicate column name") {
                    return Err(db_error(format!(
                        "migrate v12 -> v13 ({statement}): {error}"
                    )));
                }
            }
        }
    }
    conn.execute(
        "UPDATE schema_meta SET value = '13' WHERE key = 'version'",
        [],
    )
    .map_err(|error| db_error(format!("bump schema version to v13: {error}")))?;
    Ok(())
}

fn codex_runs_table_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='codex_runs'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check codex_runs table existence: {error}")))
}
