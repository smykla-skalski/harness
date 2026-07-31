use rusqlite::Connection;

use super::CliError;

const REPORT_ORDER_SQL: &str = include_str!(
    "../../harness-daemon/src/daemon/db/migrations/0063_daemon_v62_ai_review_report_order.sql"
);

/// Add a durable append sequence for retained AI review reports.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(REPORT_ORDER_SQL)
        .map_err(|error| super::db_error(format!("add AI review report order: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_order_upgrade_is_replayable_and_preserves_existing_history() {
        let conn = Connection::open_in_memory().expect("open database");
        conn.execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '61');
             CREATE TABLE task_board_ai_review_reports (
                 report_id TEXT PRIMARY KEY,
                 finished_at_unix_millis INTEGER NOT NULL
             );
             INSERT INTO task_board_ai_review_reports VALUES
                 ('report-b', 1000),
                 ('report-a', 1000),
                 ('report-c', 2000);",
        )
        .expect("seed v61 database");

        run(&conn).expect("upgrade v61 database");
        run(&conn).expect("replay upgraded database");

        let ordered = conn
            .prepare(
                "SELECT report_id
                 FROM task_board_ai_review_report_order
                 ORDER BY sequence",
            )
            .expect("prepare order query")
            .query_map([], |row| row.get::<_, String>(0))
            .expect("query order")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect order");
        assert_eq!(ordered, ["report-a", "report-b", "report-c"]);
        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("load schema version");
        assert_eq!(version, "62");
    }
}
