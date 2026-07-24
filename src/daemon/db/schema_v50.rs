use rusqlite::Connection;

use super::CliError;

const MIGRATION_SQL: &str =
    include_str!("migrations/0044_daemon_v50_codex_runs_nullable_session.sql");

/// The forward sqlx migrator runs the raw migration file against a database
/// that already holds `codex_runs` (see `schema_v32.rs`'s identical note).
/// The sync chain, by contrast, can migrate a synthetic legacy fixture that
/// never created that table -- rebuilding a table that does not exist would
/// fail on the very first `ALTER TABLE ... RENAME TO`, so this skips the
/// rebuild entirely (there is nothing to widen) and only stamps the version.
pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if !codex_runs_table_exists(conn)? {
        return stamp_schema_version(conn);
    }
    conn.execute_batch(MIGRATION_SQL)
        .map_err(|error| super::db_error(format!("apply schema v50: {error}")))
}

fn codex_runs_table_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'codex_runs'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| super::db_error(format!("check codex_runs table existence: {error}")))
}

fn stamp_schema_version(conn: &Connection) -> Result<(), CliError> {
    conn.execute("UPDATE schema_meta SET value = '50' WHERE key = 'version'", [])
        .map(|_| ())
        .map_err(|error| super::db_error(format!("stamp schema v50: {error}")))
}

#[cfg(test)]
#[path = "schema_v50_tests.rs"]
mod tests;
