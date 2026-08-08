use rusqlite::Connection;

use super::run;

/// Enough of a v64 database to exercise every object this migration rebuilds:
/// the terminal table it makes optional, the detach trigger whose body names
/// that table, and the admission child whose foreign key points at the dispatch
/// intents it replaces.
fn seed_v64(conn: &Connection) {
    conn.execute_batch(
        "PRAGMA foreign_keys = ON;
         CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
         INSERT INTO schema_meta VALUES ('version', '64');
         CREATE TABLE sessions (
             session_id TEXT PRIMARY KEY,
             status TEXT NOT NULL
         ) WITHOUT ROWID;
         CREATE TABLE agent_workspaces (
             workspace_id TEXT PRIMARY KEY,
             created_at TEXT NOT NULL,
             updated_at TEXT NOT NULL
         ) WITHOUT ROWID;
         CREATE TABLE agent_workspace_teams (
             workspace_id TEXT PRIMARY KEY
                 REFERENCES agent_workspaces(workspace_id) ON DELETE CASCADE,
             source_revision INTEGER NOT NULL,
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
             managed_agent_kind TEXT,
             managed_agent_id TEXT,
             PRIMARY KEY (workspace_id, member_id)
         ) WITHOUT ROWID;
         CREATE TABLE codex_runs (
             run_id TEXT PRIMARY KEY,
             session_id TEXT REFERENCES sessions(session_id) ON DELETE CASCADE,
             updated_at TEXT NOT NULL
         ) WITHOUT ROWID;
         CREATE TABLE agent_tuis (
             tui_id          TEXT PRIMARY KEY,
             session_id      TEXT NOT NULL
                             REFERENCES sessions(session_id) ON DELETE CASCADE,
             agent_id        TEXT NOT NULL,
             runtime         TEXT NOT NULL,
             status          TEXT NOT NULL,
             argv_json       TEXT NOT NULL,
             project_dir     TEXT NOT NULL,
             rows            INTEGER NOT NULL,
             cols            INTEGER NOT NULL,
             cursor_row      INTEGER NOT NULL,
             cursor_col      INTEGER NOT NULL,
             screen_text     TEXT NOT NULL,
             transcript_path TEXT NOT NULL,
             exit_code       INTEGER,
             signal          TEXT,
             error           TEXT,
             created_at      TEXT NOT NULL,
             updated_at      TEXT NOT NULL
         ) WITHOUT ROWID;
         CREATE INDEX idx_agent_tuis_session_updated
             ON agent_tuis(session_id, updated_at DESC);
         CREATE INDEX idx_agent_tuis_status ON agent_tuis(status);
         CREATE TRIGGER agent_workspace_team_source_tui_insert
         AFTER INSERT ON agent_tuis
         BEGIN
             UPDATE agent_workspace_teams
             SET source_revision = source_revision + 1
             WHERE workspace_id IN (
                 SELECT workspace_id FROM agent_workspace_legacy_sessions
                 WHERE session_id = NEW.session_id
             );
         END;
         CREATE TRIGGER agent_workspace_team_source_tui_update
         AFTER UPDATE ON agent_tuis BEGIN SELECT 1; END;
         CREATE TRIGGER agent_workspace_team_source_tui_delete
         AFTER DELETE ON agent_tuis BEGIN SELECT 1; END;
         CREATE TRIGGER agent_workspace_team_detach_session
         BEFORE DELETE ON sessions
         BEGIN
             SELECT RAISE(ABORT, 'detach blocked')
             WHERE EXISTS (SELECT 1 FROM agent_tuis WHERE session_id = OLD.session_id);
         END;
         CREATE TABLE task_board_items (
             item_id TEXT PRIMARY KEY,
             session_id TEXT,
             work_item_id TEXT
         );
         CREATE TABLE task_board_dispatch_intents (
             intent_id TEXT PRIMARY KEY,
             item_id TEXT NOT NULL
                 REFERENCES task_board_items(item_id) ON DELETE CASCADE,
             session_id TEXT NOT NULL,
             work_item_id TEXT NOT NULL,
             workflow_execution_id TEXT NOT NULL,
             payload_json TEXT NOT NULL,
             status TEXT NOT NULL CHECK (status IN (
                 'preparing', 'preparing_claimed', 'held', 'pending',
                 'workflow_prepared', 'starting', 'completed', 'failed'
             )),
             attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
             available_at TEXT NOT NULL,
             claim_token TEXT,
             claimed_at TEXT,
             last_error TEXT,
             created_at TEXT NOT NULL,
             updated_at TEXT NOT NULL,
             completed_at TEXT,
             consumed_approval_grant_id TEXT,
             compensation_pending INTEGER NOT NULL DEFAULT 0,
             start_admission_outcome TEXT,
             start_admission_settings_revision INTEGER
         );
         CREATE UNIQUE INDEX task_board_dispatch_intents_admission_identity
             ON task_board_dispatch_intents(intent_id, item_id);
         CREATE TABLE task_board_dispatch_admission_decisions (
             decision_id TEXT PRIMARY KEY,
             intent_id TEXT,
             item_id TEXT NOT NULL,
             FOREIGN KEY (intent_id, item_id)
                 REFERENCES task_board_dispatch_intents(intent_id, item_id)
         );
         INSERT INTO sessions VALUES ('session-1', 'active');
         INSERT INTO agent_workspaces VALUES ('workspace-1', 'created', 'updated');
         INSERT INTO agent_workspace_teams VALUES ('workspace-1', 1, 'updated');
         INSERT INTO agent_workspace_legacy_sessions VALUES ('workspace-1', 'session-1');
         INSERT INTO agent_tuis VALUES (
             'tui-1', 'session-1', 'agent-1', 'claude', 'running', '[]',
             '/projects/app', 24, 80, 0, 0, '', '/transcripts/tui-1', NULL, NULL,
             NULL, 'created', 'updated'
         );
         INSERT INTO task_board_items VALUES ('item-1', 'session-1', 'work-1');
         INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id,
             workflow_execution_id, payload_json, status, attempts,
             available_at, created_at, updated_at
         ) VALUES (
             'intent-1', 'item-1', 'session-1', 'work-1', 'workflow-1', '{}',
             'pending', 0, 'now', 'created', 'updated'
         );
         INSERT INTO task_board_dispatch_admission_decisions
         VALUES ('decision-1', 'intent-1', 'item-1');",
    )
    .expect("seed v64 database");
}

fn schema_version(conn: &Connection) -> String {
    conn.query_row(
        "SELECT value FROM schema_meta WHERE key = 'version'",
        [],
        |row| row.get(0),
    )
    .expect("load schema version")
}

#[test]
fn the_upgrade_preserves_existing_rows_and_stamps_v65() {
    let conn = Connection::open_in_memory().expect("open database");
    seed_v64(&conn);

    run(&conn).expect("upgrade v64 database");

    let tui: (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT session_id, workspace_id FROM agent_tuis WHERE tui_id = 'tui-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load migrated terminal");
    assert_eq!(tui, (Some("session-1".to_string()), None));
    let intent: (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT session_id, workspace_id FROM task_board_dispatch_intents
             WHERE intent_id = 'intent-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load migrated intent");
    assert_eq!(intent, (Some("session-1".to_string()), None));
    assert_eq!(schema_version(&conn), "65");
}

/// The repair chain replays every version step. A replay that re-ran either
/// table rebuild would copy its rows back with a NULL `workspace_id`, silently
/// unowning every worker this migration exists to give an owner.
#[test]
fn a_replay_keeps_the_ownership_the_first_run_recorded() {
    let conn = Connection::open_in_memory().expect("open database");
    seed_v64(&conn);
    run(&conn).expect("upgrade v64 database");
    conn.execute(
        "UPDATE agent_tuis SET session_id = NULL, workspace_id = 'workspace-1'
         WHERE tui_id = 'tui-1'",
        [],
    )
    .expect("hand the terminal to its workspace");
    conn.execute(
        "UPDATE task_board_dispatch_intents
         SET session_id = NULL, workspace_id = 'workspace-1',
             working_copy_id = 'copy-1'
         WHERE intent_id = 'intent-1'",
        [],
    )
    .expect("hand the intent to its workspace");

    run(&conn).expect("replay the upgrade");

    let tui: (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT session_id, workspace_id FROM agent_tuis WHERE tui_id = 'tui-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load replayed terminal");
    assert_eq!(tui, (None, Some("workspace-1".to_string())));
    let intent: (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT workspace_id, working_copy_id FROM task_board_dispatch_intents
             WHERE intent_id = 'intent-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load replayed intent");
    assert_eq!(
        intent,
        (Some("workspace-1".to_string()), Some("copy-1".to_string()))
    );
}

/// The rebuild renames both tables out of the way. Anything that still names
/// them by string - the detach trigger's body, the admission child's foreign
/// key - has to keep pointing at the rebuilt table, not at the scratch name
/// that gets dropped.
#[test]
fn rebuilt_tables_keep_the_objects_that_name_them() {
    let conn = Connection::open_in_memory().expect("open database");
    seed_v64(&conn);

    run(&conn).expect("upgrade v64 database");

    let detach = conn.execute("DELETE FROM sessions WHERE session_id = 'session-1'", []);
    assert!(
        detach.is_err_and(|error| error.to_string().contains("detach blocked")),
        "the detach trigger must still read the rebuilt agent_tuis"
    );
    let orphan = conn.execute(
        "INSERT INTO task_board_dispatch_admission_decisions
         VALUES ('decision-2', 'missing-intent', 'item-1')",
        [],
    );
    assert!(
        orphan.is_err(),
        "the admission child must still enforce its key against the rebuilt intents"
    );
}

#[test]
fn a_session_less_terminal_needs_a_workspace_owner() {
    let conn = Connection::open_in_memory().expect("open database");
    seed_v64(&conn);
    run(&conn).expect("upgrade v64 database");

    conn.execute(
        "INSERT INTO agent_tuis VALUES (
             'tui-2', NULL, 'workspace-1', 'agent-2', 'codex', 'running', '[]',
             '/copies/one', 24, 80, 0, 0, '', '/transcripts/tui-2', NULL, NULL,
             NULL, 'created', 'updated'
         )",
        [],
    )
    .expect("insert workspace-owned terminal");

    let ownerless = conn.execute(
        "INSERT INTO agent_tuis VALUES (
             'tui-3', NULL, NULL, 'agent-3', 'codex', 'running', '[]',
             '/copies/two', 24, 80, 0, 0, '', '/transcripts/tui-3', NULL, NULL,
             NULL, 'created', 'updated'
         )",
        [],
    );
    assert!(
        ownerless.is_err(),
        "a terminal with neither owner is the orphan the CHECK exists to refuse"
    );
}

#[test]
fn one_live_working_copy_owns_a_path() {
    let conn = Connection::open_in_memory().expect("open database");
    seed_v64(&conn);
    run(&conn).expect("upgrade v64 database");
    let insert = "INSERT INTO agent_working_copies (
            working_copy_id, workspace_id, origin_path, project_name,
            worktree_path, branch_ref, status, released_reason,
            created_at, updated_at
         ) VALUES (?1, 'workspace-1', '/origin', 'project', '/copies/one',
                   'harness/copy', ?2, ?3, 'created', 'updated')";

    conn.execute(
        insert,
        rusqlite::params!["copy-1", "active", None::<String>],
    )
    .expect("record the first working copy");
    let duplicate = conn.execute(
        insert,
        rusqlite::params!["copy-2", "active", None::<String>],
    );
    assert!(
        duplicate.is_err(),
        "two live working copies on one path is the duplicate checkout to refuse"
    );

    conn.execute(
        "UPDATE agent_working_copies SET status = 'released',
             released_reason = 'compensated' WHERE working_copy_id = 'copy-1'",
        [],
    )
    .expect("release the first working copy");
    conn.execute(
        insert,
        rusqlite::params!["copy-2", "active", None::<String>],
    )
    .expect("reuse the path once the prior copy is released");
}
