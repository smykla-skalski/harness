-- Terminal workers dispatched from the board own a workspace instead of a
-- Session, so `session_id` has to accept NULL and `workspace_id` becomes the
-- other half of the ownership pair.
--
-- `legacy_alter_table` keeps the rename from rewriting `agent_tuis` inside
-- `agent_workspace_team_detach_session`, whose body reads the table by name;
-- without it that trigger would be left pointing at the scratch table this
-- migration drops. The three triggers that fire *on* `agent_tuis` do follow the
-- rename, so they are dropped up front and recreated against the rebuilt table.
DROP TRIGGER IF EXISTS agent_workspace_team_source_tui_insert;
DROP TRIGGER IF EXISTS agent_workspace_team_source_tui_update;
DROP TRIGGER IF EXISTS agent_workspace_team_source_tui_delete;
DROP INDEX IF EXISTS idx_agent_tuis_session_updated;
DROP INDEX IF EXISTS idx_agent_tuis_status;

PRAGMA legacy_alter_table = ON;
ALTER TABLE agent_tuis RENAME TO agent_tuis_v64;
PRAGMA legacy_alter_table = OFF;

CREATE TABLE agent_tuis (
    tui_id          TEXT PRIMARY KEY,
    session_id      TEXT REFERENCES sessions(session_id) ON DELETE CASCADE,
    workspace_id    TEXT REFERENCES agent_workspaces(workspace_id) ON DELETE SET NULL,
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
    updated_at      TEXT NOT NULL,
    CHECK (session_id IS NOT NULL OR workspace_id IS NOT NULL)
) WITHOUT ROWID;

INSERT INTO agent_tuis (
    tui_id, session_id, workspace_id, agent_id, runtime, status, argv_json,
    project_dir, rows, cols, cursor_row, cursor_col, screen_text,
    transcript_path, exit_code, signal, error, created_at, updated_at
)
SELECT tui_id, session_id, NULL, agent_id, runtime, status, argv_json,
       project_dir, rows, cols, cursor_row, cursor_col, screen_text,
       transcript_path, exit_code, signal, error, created_at, updated_at
FROM agent_tuis_v64;

DROP TABLE agent_tuis_v64;

CREATE INDEX IF NOT EXISTS idx_agent_tuis_session_updated
    ON agent_tuis(session_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_tuis_status
    ON agent_tuis(status);
CREATE INDEX IF NOT EXISTS idx_agent_tuis_workspace_updated
    ON agent_tuis(workspace_id, updated_at DESC);

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_tui_insert
AFTER INSERT ON agent_tuis
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id = NEW.workspace_id
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_legacy_sessions
           WHERE session_id = NEW.session_id
       );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_tui_update
AFTER UPDATE ON agent_tuis
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (OLD.workspace_id, NEW.workspace_id)
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_legacy_sessions
           WHERE session_id IN (OLD.session_id, NEW.session_id)
       )
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_members
           WHERE managed_agent_kind = 'tui' AND managed_agent_id = NEW.tui_id
       );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_tui_delete
AFTER DELETE ON agent_tuis
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id = OLD.workspace_id
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_legacy_sessions
           WHERE session_id = OLD.session_id
       )
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_members
           WHERE managed_agent_kind = 'tui' AND managed_agent_id = OLD.tui_id
       );
END;
