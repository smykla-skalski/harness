use rusqlite::Connection;

use super::CliError;

const AGENT_TURN_RUNTIME_ID_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0059_daemon_v60_agent_turn_runtime_id.sql"
);

/// Add the provider-owned turn identity needed to harvest a correlated report.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    let has_runtime_turn_id = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('agent_turn_runs') WHERE name = 'runtime_turn_id'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|error| {
            super::db_error(format!(
                "inspect schema v60 agent turn runtime id column: {error}"
            ))
        })?
        != 0;
    if has_runtime_turn_id {
        return conn
            .execute(
                "UPDATE schema_meta SET value = '60' WHERE key = 'version'",
                [],
            )
            .map(|_| ())
            .map_err(|error| {
                super::db_error(format!("stamp schema v60 agent turn runtime id: {error}"))
            });
    }
    conn.execute_batch(AGENT_TURN_RUNTIME_ID_SQL)
        .map_err(|error| {
            super::db_error(format!(
                "apply schema v60 agent turn runtime id migration: {error}"
            ))
        })
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use super::run;

    #[test]
    fn migration_is_idempotent_and_stamps_the_new_version() {
        let conn = Connection::open_in_memory().expect("open memory database");
        conn.execute_batch(
            "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '59');
             CREATE TABLE agent_turn_runs (run_id TEXT PRIMARY KEY);",
        )
        .expect("seed v59 database");

        run(&conn).expect("first run v60");
        run(&conn).expect("second run v60");

        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM pragma_table_info('agent_turn_runs')
                 WHERE name = 'runtime_turn_id'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("runtime turn id column"),
            1
        );
        assert_eq!(
            conn.query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .expect("schema version"),
            "60"
        );
    }
}
