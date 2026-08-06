CREATE TABLE IF NOT EXISTS agent_workspaces (
    workspace_id               TEXT PRIMARY KEY,
    daemon_id                  TEXT NOT NULL,
    project_scope_id           TEXT NOT NULL,
    checkout_id                TEXT NOT NULL,
    source_project_id          TEXT NOT NULL,
    project_name               TEXT NOT NULL,
    checkout_name              TEXT NOT NULL,
    project_dir                TEXT,
    repository_root            TEXT,
    context_root               TEXT NOT NULL,
    is_worktree                INTEGER NOT NULL CHECK (is_worktree IN (0, 1)),
    worktree_name              TEXT,
    availability               TEXT NOT NULL
                               CHECK (availability IN ('available', 'missing_worktree')),
    selected_legacy_session_id TEXT,
    manifest_digest            TEXT NOT NULL,
    shadow_digest              TEXT NOT NULL,
    orchestration_authority    TEXT NOT NULL DEFAULT 'legacy_session'
                               CHECK (orchestration_authority IN (
                                   'no_owner', 'legacy_session', 'workspace'
                               )),
    created_at                 TEXT NOT NULL,
    updated_at                 TEXT NOT NULL,
    UNIQUE (daemon_id, project_scope_id, checkout_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_agent_workspaces_project
    ON agent_workspaces(daemon_id, project_scope_id, checkout_id);

CREATE TABLE IF NOT EXISTS agent_workspace_legacy_sessions (
    workspace_id          TEXT NOT NULL
                          REFERENCES agent_workspaces(workspace_id) ON DELETE CASCADE,
    session_id            TEXT NOT NULL,
    lifecycle             TEXT NOT NULL CHECK (lifecycle IN ('active', 'stale', 'ended')),
    checkout_availability TEXT NOT NULL
                          CHECK (checkout_availability IN ('available', 'missing_worktree')),
    liveness_evidence     TEXT NOT NULL,
    effective_activity_at TEXT,
    session_updated_at    TEXT NOT NULL,
    session_created_at    TEXT NOT NULL,
    source_digest         TEXT NOT NULL,
    is_selected           INTEGER NOT NULL CHECK (is_selected IN (0, 1)),
    PRIMARY KEY (workspace_id, session_id)
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_workspace_selected_session
    ON agent_workspace_legacy_sessions(workspace_id)
    WHERE is_selected = 1;

CREATE TABLE IF NOT EXISTS agent_workspace_reconciliation (
    daemon_id               TEXT NOT NULL,
    project_scope_id        TEXT NOT NULL,
    checkout_id             TEXT NOT NULL,
    workspace_id            TEXT,
    migration_version       INTEGER NOT NULL,
    manifest_digest         TEXT NOT NULL,
    idempotency_key         TEXT NOT NULL,
    outcome                 TEXT NOT NULL CHECK (outcome IN ('ready', 'blocked')),
    phase                   TEXT NOT NULL
                            CHECK (phase IN ('preflighted', 'committed')),
    blocker_kind            TEXT,
    blocker_detail          TEXT,
    source_session_ids_json TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    PRIMARY KEY (daemon_id, project_scope_id, checkout_id)
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_workspace_reconciliation_idempotency
    ON agent_workspace_reconciliation(idempotency_key);

CREATE TABLE IF NOT EXISTS agent_workspace_reconcile_queue (
    project_id      TEXT PRIMARY KEY,
    source_revision INTEGER NOT NULL,
    updated_at      TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO agent_workspace_reconcile_queue (project_id, source_revision, updated_at)
SELECT DISTINCT project_id, 1, datetime('now')
FROM sessions
WHERE TRUE
ON CONFLICT(project_id) DO NOTHING;

CREATE TRIGGER IF NOT EXISTS agent_workspace_queue_session_insert
AFTER INSERT ON sessions
BEGIN
    INSERT INTO agent_workspace_reconcile_queue (project_id, source_revision, updated_at)
    VALUES (NEW.project_id, 1, datetime('now'))
    ON CONFLICT(project_id) DO UPDATE SET
        source_revision = agent_workspace_reconcile_queue.source_revision + 1,
        updated_at = excluded.updated_at;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_queue_session_update
AFTER UPDATE ON sessions
BEGIN
    INSERT INTO agent_workspace_reconcile_queue (project_id, source_revision, updated_at)
    VALUES (NEW.project_id, 1, datetime('now'))
    ON CONFLICT(project_id) DO UPDATE SET
        source_revision = agent_workspace_reconcile_queue.source_revision + 1,
        updated_at = excluded.updated_at;
    INSERT INTO agent_workspace_reconcile_queue (project_id, source_revision, updated_at)
    SELECT OLD.project_id, 1, datetime('now')
    WHERE OLD.project_id <> NEW.project_id
    ON CONFLICT(project_id) DO UPDATE SET
        source_revision = agent_workspace_reconcile_queue.source_revision + 1,
        updated_at = excluded.updated_at;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_queue_session_delete
AFTER DELETE ON sessions
BEGIN
    INSERT INTO agent_workspace_reconcile_queue (project_id, source_revision, updated_at)
    VALUES (OLD.project_id, 1, datetime('now'))
    ON CONFLICT(project_id) DO UPDATE SET
        source_revision = agent_workspace_reconcile_queue.source_revision + 1,
        updated_at = excluded.updated_at;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_queue_project_update
AFTER UPDATE ON projects
BEGIN
    INSERT INTO agent_workspace_reconcile_queue (project_id, source_revision, updated_at)
    SELECT NEW.project_id, 1, datetime('now')
    WHERE EXISTS (SELECT 1 FROM sessions WHERE project_id = NEW.project_id)
    ON CONFLICT(project_id) DO UPDATE SET
        source_revision = agent_workspace_reconcile_queue.source_revision + 1,
        updated_at = excluded.updated_at;
END;

UPDATE schema_meta SET value = '63' WHERE key = 'version';
