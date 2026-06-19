CREATE TABLE IF NOT EXISTS policy_decisions (
    id                    TEXT PRIMARY KEY,
    recorded_at           TEXT NOT NULL,
    canvas_id             TEXT,
    revision              INTEGER NOT NULL,
    action                TEXT NOT NULL,
    decision_tag          TEXT NOT NULL,
    reason_code           TEXT NOT NULL,
    policy_version        TEXT NOT NULL,
    workflow              TEXT,
    subject_json          TEXT NOT NULL,
    evidence_json         TEXT NOT NULL,
    visited_node_ids_json TEXT NOT NULL DEFAULT '[]',
    source                TEXT NOT NULL,
    enforced              INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_policy_decisions_recorded_at
    ON policy_decisions(recorded_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_policy_decisions_action
    ON policy_decisions(action, recorded_at DESC);

UPDATE schema_meta SET value = '24' WHERE key = 'version';
