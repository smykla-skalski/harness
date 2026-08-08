use rusqlite::Connection;

use super::CliError;

const RUNTIME_SESSION_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0076_daemon_v68_agent_signal_runtime_session.sql"
);
const PROJECT_DIR_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0077_daemon_v68_agent_signal_project_dir.sql"
);
const DELIVERY_BACKFILL_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0078_daemon_v68_agent_signal_delivery_backfill.sql"
);
const DELIVERY_STAMP_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0079_daemon_v68_agent_signal_delivery_stamp.sql"
);

/// Persist the exact runtime delivery route for each native agent signal.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    add_column_if_missing(
        conn,
        "delivery_runtime_session_id",
        RUNTIME_SESSION_SQL,
        "runtime session",
    )?;
    add_column_if_missing(
        conn,
        "delivery_project_dir",
        PROJECT_DIR_SQL,
        "project directory",
    )?;
    conn.execute_batch(DELIVERY_BACKFILL_SQL).map_err(|error| {
        super::db_error(format!("backfill agent signal delivery routes: {error}"))
    })?;
    conn.execute_batch(DELIVERY_STAMP_SQL)
        .map_err(|error| super::db_error(format!("stamp agent signal delivery routes: {error}")))
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
        .map_err(|error| super::db_error(format!("inspect signal delivery {label}: {error}")))?;
    if exists {
        return Ok(());
    }
    conn.execute_batch(migration)
        .map_err(|error| super::db_error(format!("add signal delivery {label}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delivery_snapshot_upgrade_backfills_and_replays_from_v67() {
        let conn = Connection::open_in_memory().expect("open database");
        conn.execute_batch(
            "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '67');
             CREATE TABLE agent_workspaces (
                 workspace_id TEXT PRIMARY KEY,
                 project_dir TEXT,
                 context_root TEXT NOT NULL
             );
             CREATE TABLE agent_workspace_members (
                 workspace_id TEXT NOT NULL,
                 member_id TEXT NOT NULL,
                 runtime_session_id TEXT,
                 source_session_id TEXT,
                 source_agent_id TEXT,
                 PRIMARY KEY (workspace_id, member_id)
             );
             CREATE TABLE agent_workspace_signals (
                 workspace_id TEXT NOT NULL,
                 member_id TEXT NOT NULL,
                 signal_id TEXT NOT NULL,
                 origin_kind TEXT NOT NULL,
                 source_session_id TEXT,
                 source_agent_id TEXT,
                 PRIMARY KEY (workspace_id, signal_id)
             );
             INSERT INTO agent_workspaces VALUES ('workspace-1', '/tmp/project', '/tmp/context');
             INSERT INTO agent_workspace_members VALUES (
                 'workspace-1', 'member-1', 'runtime-1', 'session-1', 'agent-1'
             );
             INSERT INTO agent_workspace_signals VALUES (
                 'workspace-1', 'member-1', 'signal-1', 'native', NULL, NULL
             );",
        )
        .expect("seed v67 database");

        run(&conn).expect("upgrade v67 database");
        run(&conn).expect("replay upgraded database");

        let route: (String, String, String, String) = conn
            .query_row(
                "SELECT source_session_id, source_agent_id,
                        delivery_runtime_session_id, delivery_project_dir
                 FROM agent_workspace_signals WHERE signal_id = 'signal-1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("load backfilled delivery route");
        assert_eq!(
            route,
            (
                "session-1".into(),
                "agent-1".into(),
                "runtime-1".into(),
                "/tmp/project".into()
            )
        );
        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("load schema version");
        assert_eq!(version, "68");
    }
}
