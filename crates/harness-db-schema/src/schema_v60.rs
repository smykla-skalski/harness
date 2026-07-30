use rusqlite::Connection;

use super::CliError;

const AGENT_TURN_RUNTIME_ID_SQL: &str = include_str!(
    "../../harness-daemon/src/daemon/db/migrations/0059_daemon_v60_agent_turn_runtime_id.sql"
);
const REQUESTED_RUNTIME_SQL: &str = include_str!(
    "../../harness-daemon/src/daemon/db/migrations/0060_daemon_v60_ai_review_requested_runtime.sql"
);
const ACTUAL_RUNTIME_SQL: &str = include_str!(
    "../../harness-daemon/src/daemon/db/migrations/0061_daemon_v60_ai_review_actual_runtime.sql"
);
const RUNTIME_BACKFILL_SQL: &str = include_str!(
    "../../harness-daemon/src/daemon/db/migrations/0062_daemon_v60_ai_review_runtime_backfill.sql"
);

/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    add_column_if_missing(
        conn,
        "agent_turn_runs",
        "runtime_turn_id",
        AGENT_TURN_RUNTIME_ID_SQL,
    )?;
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
    fn runtime_provenance_upgrade_replays_after_every_partial_alter() {
        let conn = Connection::open_in_memory().expect("open database");
        conn.execute_batch(
            "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '59');
             CREATE TABLE agent_turn_runs (run_id TEXT PRIMARY KEY);
             CREATE TABLE task_board_ai_review_reports (
                 report_id TEXT PRIMARY KEY,
                 runtime TEXT NOT NULL
             );
             INSERT INTO task_board_ai_review_reports VALUES ('report-1', 'openrouter');",
        )
        .expect("seed v59 database");

        run(&conn).expect("upgrade v59 database");
        run(&conn).expect("replay upgraded database");

        let runtime_turn_id_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('agent_turn_runs')
                 WHERE name = 'runtime_turn_id'",
                [],
                |row| row.get(0),
            )
            .expect("load runtime turn id count");
        assert_eq!(runtime_turn_id_count, 1);
        let provenance: (String, String) = conn
            .query_row(
                "SELECT requested_runtime, actual_runtime
                 FROM task_board_ai_review_reports
                 WHERE report_id = 'report-1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load backfilled provenance");
        assert_eq!(provenance, ("openrouter".into(), "openrouter".into()));
        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("load schema version");
        assert_eq!(version, "60");
    }
}
