-- Schema version tracking
CREATE TABLE schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO schema_meta (key, value) VALUES ('version', '8');

-- Discovered projects
CREATE TABLE projects (
    project_id      TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    project_dir     TEXT,
    repository_root TEXT,
    checkout_id     TEXT NOT NULL,
    checkout_name   TEXT NOT NULL,
    context_root    TEXT NOT NULL UNIQUE,
    is_worktree     INTEGER NOT NULL DEFAULT 0,
    worktree_name   TEXT,
    origin_json     TEXT,
    discovered_at   TEXT NOT NULL,
    updated_at      TEXT NOT NULL
) WITHOUT ROWID;

CREATE INDEX idx_projects_repository_root ON projects(repository_root);

-- Orchestration sessions
CREATE TABLE sessions (
    session_id              TEXT PRIMARY KEY,
    project_id              TEXT NOT NULL REFERENCES projects(project_id),
    schema_version          INTEGER NOT NULL,
    state_version           INTEGER NOT NULL DEFAULT 0,
    title                   TEXT NOT NULL DEFAULT '',
    context                 TEXT NOT NULL,
    status                  TEXT NOT NULL,
    leader_id               TEXT,
    observe_id              TEXT,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    last_activity_at        TEXT,
    archived_at             TEXT,
    pending_leader_transfer TEXT,
    metrics_json            TEXT NOT NULL DEFAULT '{}',
    state_json              TEXT NOT NULL,
    is_active               INTEGER NOT NULL DEFAULT 1
) WITHOUT ROWID;

CREATE INDEX idx_sessions_project ON sessions(project_id);
CREATE INDEX idx_sessions_active ON sessions(is_active) WHERE is_active = 1;
CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC);

-- Registered agents per session
CREATE TABLE agents (
    agent_id                  TEXT NOT NULL,
    session_id                TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    name                      TEXT NOT NULL,
    runtime                   TEXT NOT NULL,
    role                      TEXT NOT NULL,
    capabilities_json         TEXT NOT NULL DEFAULT '[]',
    status                    TEXT NOT NULL,
    agent_session_id          TEXT,
    joined_at                 TEXT NOT NULL,
    updated_at                TEXT NOT NULL,
    last_activity_at          TEXT,
    current_task_id           TEXT,
    runtime_capabilities_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (session_id, agent_id)
) WITHOUT ROWID;

CREATE INDEX idx_agents_runtime_session ON agents(runtime, agent_session_id);

-- Work items per session
CREATE TABLE tasks (
    task_id                 TEXT NOT NULL,
    session_id              TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    title                   TEXT NOT NULL,
    context                 TEXT,
    severity                TEXT NOT NULL,
    status                  TEXT NOT NULL,
    assigned_to             TEXT,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    created_by              TEXT,
    suggested_fix           TEXT,
    source                  TEXT NOT NULL DEFAULT 'manual',
    blocked_reason          TEXT,
    completed_at            TEXT,
    notes_json              TEXT NOT NULL DEFAULT '[]',
    checkpoint_summary_json TEXT,
    PRIMARY KEY (session_id, task_id)
) WITHOUT ROWID;

CREATE INDEX idx_tasks_session_status ON tasks(session_id, status);

-- Append-only session audit log
CREATE TABLE session_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    sequence        INTEGER NOT NULL,
    recorded_at     TEXT NOT NULL,
    transition_kind TEXT NOT NULL,
    transition_json TEXT NOT NULL,
    actor_id        TEXT,
    reason          TEXT,
    UNIQUE(session_id, sequence)
);

CREATE INDEX idx_session_log_session_time ON session_log(session_id, recorded_at);

-- Append-only task checkpoints
CREATE TABLE task_checkpoints (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    checkpoint_id TEXT NOT NULL UNIQUE,
    task_id       TEXT NOT NULL,
    session_id    TEXT NOT NULL,
    recorded_at   TEXT NOT NULL,
    actor_id      TEXT,
    summary       TEXT NOT NULL,
    progress      INTEGER NOT NULL,
    FOREIGN KEY (session_id, task_id) REFERENCES tasks(session_id, task_id) ON DELETE CASCADE
);

CREATE INDEX idx_checkpoints_task ON task_checkpoints(session_id, task_id);

-- Read-through index of signal files (files remain on disk)
CREATE TABLE signal_index (
    signal_id    TEXT PRIMARY KEY,
    session_id   TEXT NOT NULL,
    agent_id     TEXT NOT NULL,
    runtime      TEXT NOT NULL,
    command      TEXT NOT NULL,
    priority     TEXT NOT NULL,
    status       TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    source_agent TEXT NOT NULL,
    message      TEXT NOT NULL,
    action_hint  TEXT,
    signal_json  TEXT NOT NULL,
    ack_json     TEXT,
    file_path    TEXT NOT NULL,
    indexed_at   TEXT NOT NULL
) WITHOUT ROWID;

CREATE INDEX idx_signals_session ON signal_index(session_id);
CREATE INDEX idx_signals_session_agent ON signal_index(session_id, agent_id);

-- Daemon audit events (replaces events.jsonl)
CREATE TABLE daemon_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at TEXT NOT NULL,
    level       TEXT NOT NULL,
    message     TEXT NOT NULL
);

CREATE INDEX idx_daemon_events_time ON daemon_events(recorded_at DESC);
CREATE UNIQUE INDEX idx_daemon_events_identity
    ON daemon_events(recorded_at, level, message);

-- Indexed conversation events from agent transcripts
CREATE TABLE conversation_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    agent_id   TEXT NOT NULL,
    runtime    TEXT NOT NULL,
    timestamp  TEXT,
    sequence   INTEGER NOT NULL DEFAULT 0,
    kind       TEXT NOT NULL,
    event_json TEXT NOT NULL
);

CREATE INDEX idx_conv_events_session ON conversation_events(session_id);
CREATE INDEX idx_conv_events_agent ON conversation_events(session_id, agent_id);
CREATE UNIQUE INDEX idx_conv_events_identity
    ON conversation_events(session_id, agent_id, sequence);

-- Canonical session timeline ledger
CREATE TABLE session_timeline_entries (
    session_id       TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    entry_id         TEXT NOT NULL,
    source_kind      TEXT NOT NULL,
    source_key       TEXT NOT NULL,
    recorded_at      TEXT NOT NULL,
    kind             TEXT NOT NULL,
    agent_id         TEXT,
    task_id          TEXT,
    summary          TEXT NOT NULL,
    payload_json     TEXT NOT NULL,
    sort_recorded_at TEXT NOT NULL,
    sort_tiebreaker  TEXT NOT NULL,
    PRIMARY KEY (session_id, source_kind, source_key)
) WITHOUT ROWID;

CREATE UNIQUE INDEX idx_session_timeline_entries_entry_id
    ON session_timeline_entries(session_id, entry_id);
CREATE INDEX idx_session_timeline_entries_session_sort
    ON session_timeline_entries(session_id, sort_recorded_at DESC, sort_tiebreaker DESC);

CREATE TABLE session_timeline_state (
    session_id         TEXT PRIMARY KEY REFERENCES sessions(session_id) ON DELETE CASCADE,
    revision           INTEGER NOT NULL DEFAULT 0,
    entry_count        INTEGER NOT NULL DEFAULT 0,
    newest_recorded_at TEXT,
    oldest_recorded_at TEXT,
    integrity_hash     TEXT NOT NULL DEFAULT '',
    updated_at         TEXT NOT NULL
) WITHOUT ROWID;

-- Cached agent activity summaries (computed from transcript files)
CREATE TABLE agent_activity_cache (
    agent_id      TEXT NOT NULL,
    session_id    TEXT NOT NULL,
    runtime       TEXT NOT NULL,
    activity_json TEXT NOT NULL,
    cached_at     TEXT NOT NULL,
    PRIMARY KEY (session_id, agent_id)
) WITHOUT ROWID;

-- Change tracking for the watch loop
CREATE TABLE change_tracking (
    scope      TEXT PRIMARY KEY,
    version    INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    change_seq INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;
CREATE INDEX idx_change_tracking_change_seq
    ON change_tracking(change_seq);

CREATE TABLE change_tracking_state (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    last_seq  INTEGER NOT NULL
) WITHOUT ROWID;

-- Cached diagnostics metadata (avoids process spawns and directory walks)
CREATE TABLE diagnostics_cache (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE codex_runs (
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

CREATE INDEX idx_codex_runs_session_updated
    ON codex_runs(session_id, updated_at DESC);
CREATE INDEX idx_codex_runs_status
    ON codex_runs(status);

CREATE TABLE agent_tuis (
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

CREATE INDEX idx_agent_tuis_session_updated
    ON agent_tuis(session_id, updated_at DESC);
CREATE INDEX idx_agent_tuis_status
    ON agent_tuis(status);

INSERT INTO change_tracking (scope, version, updated_at)
VALUES ('global', 0, datetime('now'));
INSERT INTO change_tracking_state (singleton, last_seq)
VALUES (1, 0);
