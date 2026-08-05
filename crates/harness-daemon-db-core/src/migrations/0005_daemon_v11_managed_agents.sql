DROP INDEX IF EXISTS idx_agents_runtime_session;
CREATE TABLE agents_v11 (
    agent_id                  TEXT NOT NULL,
    session_id                TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    name                      TEXT NOT NULL,
    runtime                   TEXT NOT NULL,
    role                      TEXT NOT NULL,
    capabilities_json         TEXT NOT NULL DEFAULT '[]',
    status                    TEXT NOT NULL,
    agent_session_id          TEXT,
    managed_agent_kind        TEXT,
    managed_agent_id          TEXT,
    joined_at                 TEXT NOT NULL,
    updated_at                TEXT NOT NULL,
    last_activity_at          TEXT,
    current_task_id           TEXT,
    runtime_capabilities_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (session_id, agent_id)
) WITHOUT ROWID;
INSERT INTO agents_v11 (
    agent_id,
    session_id,
    name,
    runtime,
    role,
    capabilities_json,
    status,
    agent_session_id,
    managed_agent_kind,
    managed_agent_id,
    joined_at,
    updated_at,
    last_activity_at,
    current_task_id,
    runtime_capabilities_json
)
SELECT
    agent_id,
    session_id,
    name,
    runtime,
    role,
    capabilities_json,
    status,
    agent_session_id,
    NULL,
    NULL,
    joined_at,
    updated_at,
    last_activity_at,
    current_task_id,
    runtime_capabilities_json
FROM agents;
DROP TABLE agents;
ALTER TABLE agents_v11 RENAME TO agents;
CREATE INDEX idx_agents_runtime_session ON agents(runtime, agent_session_id);
UPDATE schema_meta SET value = '11' WHERE key = 'version';
