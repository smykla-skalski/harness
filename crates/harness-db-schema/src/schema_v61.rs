use rusqlite::Connection;

use super::CliError;

const REQUESTED_RUNTIME_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0060_daemon_v61_ai_review_requested_runtime.sql"
);
const ACTUAL_RUNTIME_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0061_daemon_v61_ai_review_actual_runtime.sql"
);
const RUNTIME_BACKFILL_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0062_daemon_v61_ai_review_runtime_backfill.sql"
);

/// Add explicit requested and actual runtime provenance to retained AI reviews.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    add_column_if_missing(
        conn,
        "task_board_ai_review_reports",
        "requested_runtime",
        REQUESTED_RUNTIME_SQL,
    )?;
    add_column_if_missing(
        conn,
        "task_board_ai_review_reports",
        "actual_runtime",
        ACTUAL_RUNTIME_SQL,
    )?;
    conn.execute_batch(RUNTIME_BACKFILL_SQL)
        .map_err(|error| super::db_error(format!("backfill AI review runtimes: {error}")))
}

fn add_column_if_missing(
    conn: &Connection,
    table: &str,
    column: &str,
    migration: &str,
) -> Result<(), CliError> {
    let exists = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
            [table, column],
            |row| row.get::<_, i64>(0),
        )
        .map(|count| count > 0)
        .map_err(|error| super::db_error(format!("check {table}.{column}: {error}")))?;
    if exists {
        return Ok(());
    }
    conn.execute_batch(migration)
        .map_err(|error| super::db_error(format!("add {table}.{column}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_provenance_upgrade_replays_from_released_v60() {
        let conn = Connection::open_in_memory().expect("open database");
        conn.execute_batch(
            "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '60');
             CREATE TABLE task_board_ai_review_reports (
                 report_id TEXT PRIMARY KEY,
                 runtime TEXT NOT NULL
             );
             INSERT INTO task_board_ai_review_reports VALUES ('report-1', 'openrouter');",
        )
        .expect("seed v60 database");

        run(&conn).expect("upgrade v60 database");
        run(&conn).expect("replay upgraded database");

        let provenance: (String, String) = conn
            .query_row(
                "SELECT requested_runtime, actual_runtime
                 FROM task_board_ai_review_reports
                 WHERE report_id = 'report-1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load backfilled provenance");
        assert_eq!(provenance, ("openrouter".into(), "codex".into()));
        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("load schema version");
        assert_eq!(version, "61");
    }
}
