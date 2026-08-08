use rusqlite::Connection;

use super::CliError;

const AGENT_SIGNAL_IDEMPOTENCY_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0072_daemon_v67_agent_signal_idempotency.sql"
);
const AGENT_SIGNAL_IDEMPOTENCY_INDEX_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0073_daemon_v67_agent_signal_idempotency_index.sql"
);
const AGENT_SIGNAL_WAKE_CLAIM_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0074_daemon_v67_agent_signal_wake_claim.sql"
);
const AGENT_SIGNAL_STAMP_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0075_daemon_v67_agent_signal_stamp.sql"
);

/// Add a durable lease for managed-agent signal wake delivery.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    add_column_if_missing(
        conn,
        "idempotency_key",
        AGENT_SIGNAL_IDEMPOTENCY_SQL,
        "idempotency key",
    )?;
    conn.execute_batch(AGENT_SIGNAL_IDEMPOTENCY_INDEX_SQL)
        .map_err(|error| super::db_error(format!("index durable signal idempotency: {error}")))?;
    add_column_if_missing(
        conn,
        "wake_claimed_at",
        AGENT_SIGNAL_WAKE_CLAIM_SQL,
        "wake claim",
    )?;
    conn.execute_batch(AGENT_SIGNAL_STAMP_SQL)
        .map_err(|error| super::db_error(format!("stamp durable signal wake claim: {error}")))
}

fn add_column_if_missing(
    conn: &Connection,
    column: &str,
    migration: &str,
    label: &str,
) -> Result<(), CliError> {
    let exists = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('agent_workspace_signals') WHERE name = ?1",
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|count| count > 0)
        .map_err(|error| super::db_error(format!("inspect durable signal {label}: {error}")))?;
    if exists {
        return Ok(());
    }
    conn.execute_batch(migration)
        .map_err(|error| super::db_error(format!("add durable signal {label}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wake_claim_upgrade_replays_from_v66() {
        let conn = Connection::open_in_memory().expect("open database");
        conn.execute_batch(
            "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '66');
             CREATE TABLE agent_workspace_signals (
                 workspace_id TEXT NOT NULL,
                 member_id TEXT NOT NULL,
                 signal_id TEXT NOT NULL,
                 PRIMARY KEY (workspace_id, signal_id)
             ) WITHOUT ROWID;",
        )
        .expect("seed v66 database");

        run(&conn).expect("upgrade v66 database");
        run(&conn).expect("replay upgraded database");

        let column_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('agent_workspace_signals')
                 WHERE name IN ('idempotency_key', 'wake_claimed_at')",
                [],
                |row| row.get(0),
            )
            .expect("load wake claim column");
        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("load schema version");
        assert_eq!(column_count, 2);
        assert_eq!(version, "67");
    }
}
