use rusqlite::Connection;

use super::CliError;

const AGENT_WORKSPACE_ACTIVITY_SQL: &str =
    include_str!("../../harness-daemon-db-core/src/migrations/0071_daemon_v66_agent_activity.sql");

/// Add workspace-owned signals, transcripts, activity summaries, and timelines.
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(AGENT_WORKSPACE_ACTIVITY_SQL)
        .map_err(|error| super::db_error(format!("add durable agent activity: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activity_upgrade_is_replayable_and_tracks_legacy_sources() {
        let conn = Connection::open_in_memory().expect("open database");
        conn.execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '65');
             CREATE TABLE sessions (session_id TEXT PRIMARY KEY) WITHOUT ROWID;
             CREATE TABLE agent_workspace_teams (
                 workspace_id TEXT PRIMARY KEY,
                 created_at TEXT NOT NULL,
                 updated_at TEXT NOT NULL
             ) WITHOUT ROWID;
             CREATE TABLE agent_workspace_legacy_sessions (
                 workspace_id TEXT NOT NULL,
                 session_id TEXT NOT NULL,
                 PRIMARY KEY (workspace_id, session_id)
             ) WITHOUT ROWID;
             CREATE TABLE agent_workspace_members (
                 workspace_id TEXT NOT NULL,
                 member_id TEXT NOT NULL,
                 PRIMARY KEY (workspace_id, member_id)
             ) WITHOUT ROWID;
             CREATE TABLE agent_workspace_member_provenance (
                 workspace_id TEXT NOT NULL,
                 member_id TEXT NOT NULL,
                 source_session_id TEXT NOT NULL,
                 source_agent_id TEXT NOT NULL,
                 PRIMARY KEY (workspace_id, source_session_id, source_agent_id)
             ) WITHOUT ROWID;
             CREATE TABLE signal_index (
                 signal_id TEXT PRIMARY KEY,
                 session_id TEXT NOT NULL,
                 agent_id TEXT NOT NULL
             ) WITHOUT ROWID;
             CREATE TABLE conversation_events (
                 id INTEGER PRIMARY KEY,
                 session_id TEXT NOT NULL,
                 agent_id TEXT NOT NULL
             );
             CREATE TABLE agent_activity_cache (
                 session_id TEXT NOT NULL,
                 agent_id TEXT NOT NULL,
                 PRIMARY KEY (session_id, agent_id)
             ) WITHOUT ROWID;
             CREATE TABLE session_timeline_entries (
                 session_id TEXT NOT NULL,
                 source_kind TEXT NOT NULL,
                 source_key TEXT NOT NULL,
                 agent_id TEXT,
                 PRIMARY KEY (session_id, source_kind, source_key)
             ) WITHOUT ROWID;
             INSERT INTO sessions VALUES ('session-1');
             INSERT INTO agent_workspace_teams VALUES ('workspace-1', 'created', 'updated');
             INSERT INTO agent_workspace_legacy_sessions VALUES ('workspace-1', 'session-1');",
        )
        .expect("seed v65 database");

        run(&conn).expect("upgrade v65 database");
        run(&conn).expect("replay upgraded database");
        conn.execute("INSERT INTO sessions VALUES ('session-2')", [])
            .expect("insert later Session");
        conn.execute(
            "INSERT INTO agent_workspace_legacy_sessions VALUES ('workspace-2', 'session-2')",
            [],
        )
        .expect("insert provenance before team");
        conn.execute(
            "INSERT INTO agent_workspace_teams VALUES ('workspace-2', 'created', 'updated')",
            [],
        )
        .expect("insert team after provenance");
        conn.execute(
            "INSERT INTO signal_index VALUES ('signal-1', 'session-1', 'agent-1')",
            [],
        )
        .expect("insert legacy signal");

        let state: (i64, i64) = conn
            .query_row(
                "SELECT source_revision, reconciled_revision
                 FROM agent_workspace_activity_state WHERE workspace_id = 'workspace-1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load activity state");
        assert_eq!(state, (2, 0));
        let later_source: String = conn
            .query_row(
                "SELECT status FROM agent_workspace_activity_sources
                 WHERE workspace_id = 'workspace-2' AND source_session_id = 'session-2'",
                [],
                |row| row.get(0),
            )
            .expect("load activity source created after migration");
        assert_eq!(later_source, "active");
        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("load schema version");
        assert_eq!(version, "66");
    }
}
