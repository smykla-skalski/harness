pub(super) const CODEX_RUNS_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS codex_runs (
    run_id                 TEXT PRIMARY KEY,
    session_id             TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    project_dir            TEXT NOT NULL,
    thread_id              TEXT,
    turn_id                TEXT,
    mode                   TEXT NOT NULL,
    status                 TEXT NOT NULL,
    prompt                 TEXT NOT NULL,
    latest_summary         TEXT,
    final_message          TEXT,
    error                  TEXT,
    pending_approvals_json TEXT NOT NULL DEFAULT '[]',
    created_at             TEXT NOT NULL,
    updated_at             TEXT NOT NULL
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_codex_runs_session_updated
    ON codex_runs(session_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_codex_runs_status
    ON codex_runs(status);
";

pub(super) const AGENT_TUIS_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS agent_tuis (
    tui_id          TEXT PRIMARY KEY,
    session_id      TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
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

CREATE INDEX IF NOT EXISTS idx_agent_tuis_session_updated
    ON agent_tuis(session_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_tuis_status
    ON agent_tuis(status);
";

pub(super) const CREATE_SCHEMA: &str = include_str!("migrations/0001_daemon_v7_baseline.sql");
