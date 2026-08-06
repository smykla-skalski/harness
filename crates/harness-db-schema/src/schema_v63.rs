use rusqlite::Connection;

use super::CliError;

const AGENT_WORKSPACES_SQL: &str = include_str!(
    "../../harness-daemon-db-core/src/migrations/0064_daemon_v63_agent_workspaces.sql"
);

/// Add durable agent workspaces and the legacy reconciliation journal.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(AGENT_WORKSPACES_SQL)
        .map_err(|error| super::db_error(format!("add durable agent workspaces: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_upgrade_is_replayable_and_tracks_legacy_writes() {
        let conn = Connection::open_in_memory().expect("open database");
        conn.execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '62');
             CREATE TABLE projects (
                 project_id TEXT PRIMARY KEY,
                 name TEXT NOT NULL,
                 project_dir TEXT,
                 repository_root TEXT,
                 checkout_id TEXT NOT NULL,
                 checkout_name TEXT NOT NULL,
                 context_root TEXT NOT NULL UNIQUE,
                 is_worktree INTEGER NOT NULL DEFAULT 0,
                 worktree_name TEXT
             ) WITHOUT ROWID;
             CREATE TABLE sessions (
                 session_id TEXT PRIMARY KEY,
                 project_id TEXT NOT NULL REFERENCES projects(project_id),
                 updated_at TEXT NOT NULL
             ) WITHOUT ROWID;
             INSERT INTO projects VALUES (
                 'checkout-1', 'Harness', '/tmp/harness', '/tmp/harness',
                 'checkout-1', 'main', '/tmp/context', 0, NULL
             );
             INSERT INTO sessions VALUES ('session-1', 'checkout-1', '2026-08-06T10:00:00Z');",
        )
        .expect("seed v62 database");

        run(&conn).expect("upgrade v62 database");
        run(&conn).expect("replay upgraded database");

        let revision: i64 = conn
            .query_row(
                "SELECT source_revision FROM agent_workspace_reconcile_queue
                 WHERE project_id = 'checkout-1'",
                [],
                |row| row.get(0),
            )
            .expect("load initial revision");
        assert_eq!(revision, 1);

        conn.execute(
            "UPDATE sessions SET updated_at = '2026-08-06T10:01:00Z'
             WHERE session_id = 'session-1'",
            [],
        )
        .expect("update legacy session");
        let revision: i64 = conn
            .query_row(
                "SELECT source_revision FROM agent_workspace_reconcile_queue
                 WHERE project_id = 'checkout-1'",
                [],
                |row| row.get(0),
            )
            .expect("load updated revision");
        assert_eq!(revision, 2);
        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("load schema version");
        assert_eq!(version, "63");
    }
}
