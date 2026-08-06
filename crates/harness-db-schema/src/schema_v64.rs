use rusqlite::Connection;

use super::CliError;

const AGENT_WORKSPACE_TEAMS_SQL: &str =
    include_str!("../../harness-daemon-db-core/src/migrations/0065_daemon_v64_agent_teams.sql");

/// Add workspace-owned agent teams, runtime bindings, and operation results.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(AGENT_WORKSPACE_TEAMS_SQL)
        .map_err(|error| super::db_error(format!("add durable agent teams: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn team_upgrade_is_replayable_and_tracks_source_changes() {
        let conn = Connection::open_in_memory().expect("open database");
        conn.execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '63');
             CREATE TABLE agent_workspaces (
                 workspace_id TEXT PRIMARY KEY,
                 selected_legacy_session_id TEXT,
                 created_at TEXT NOT NULL,
                 updated_at TEXT NOT NULL
             ) WITHOUT ROWID;
             CREATE TABLE agent_workspace_legacy_sessions (
                 workspace_id TEXT NOT NULL,
                 session_id TEXT NOT NULL,
                 lifecycle TEXT NOT NULL,
                 PRIMARY KEY (workspace_id, session_id)
             ) WITHOUT ROWID;
             CREATE TABLE sessions (
                 session_id TEXT PRIMARY KEY,
                 leader_id TEXT,
                 status TEXT NOT NULL,
                 state_json TEXT NOT NULL
             ) WITHOUT ROWID;
             CREATE TABLE agents (
                 agent_id TEXT NOT NULL,
                 session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
                 PRIMARY KEY (session_id, agent_id)
             ) WITHOUT ROWID;
             CREATE TABLE agent_tuis (
                 tui_id TEXT PRIMARY KEY,
                 session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE
             ) WITHOUT ROWID;
             CREATE TABLE codex_runs (
                 run_id TEXT PRIMARY KEY,
                 session_id TEXT REFERENCES sessions(session_id) ON DELETE CASCADE
             ) WITHOUT ROWID;
             INSERT INTO agent_workspaces
             VALUES ('workspace-1', 'session-1', 'created', 'updated');
             INSERT INTO sessions VALUES ('session-1', NULL, 'active', '{}');
             INSERT INTO agent_workspace_legacy_sessions
             VALUES ('workspace-1', 'session-1', 'active');",
        )
        .expect("seed v63 database");

        run(&conn).expect("upgrade v63 database");
        run(&conn).expect("replay upgraded database");
        conn.execute("INSERT INTO agents VALUES ('agent-1', 'session-1')", [])
            .expect("insert legacy agent");

        let revision: i64 = conn
            .query_row(
                "SELECT source_revision FROM agent_workspace_teams WHERE workspace_id = 'workspace-1'",
                [],
                |row| row.get(0),
            )
            .expect("load source revision");
        assert_eq!(revision, 2);
        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("load schema version");
        assert_eq!(version, "64");
        let team_root: (String, String, i64, i64) = conn
            .query_row(
                "SELECT selected_legacy_session_id, selected_lifecycle,
                        source_revision, reconciled_revision
                 FROM agent_workspace_teams WHERE workspace_id = 'workspace-1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("load backfilled team root");
        assert_eq!(
            team_root,
            ("session-1".to_string(), "active".to_string(), 2, 0)
        );
    }
}
