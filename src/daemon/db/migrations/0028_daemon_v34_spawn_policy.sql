-- WP3 spawn-policy schema: evaluation timestamp on the decision feed, durable
-- approval grants for the ApprovalGate node, and the persisted spawn switches.

-- D1/D5: caller-supplied evaluation timestamp persisted with the decision feed
-- so replay can restore a deterministic evaluated-at. Nullable for legacy rows.
ALTER TABLE policy_decisions ADD COLUMN evaluated_at TEXT;

-- D2: durable one-shot approval grants keyed by board item + action + the canvas
-- revision that authored the ApprovalGate. A grant moves pending -> approved |
-- denied, then is consumed once at dispatch reservation. The partial unique index
-- allows at most one live (unconsumed) grant per key while a fresh grant can be
-- created after consumption.
CREATE TABLE IF NOT EXISTS policy_approval_grants (
    id             TEXT PRIMARY KEY,
    board_item_id  TEXT NOT NULL,
    action         TEXT NOT NULL,
    canvas_id      TEXT,
    canvas_revision INTEGER NOT NULL,
    node_id        TEXT NOT NULL,
    reason_code    TEXT NOT NULL,
    state          TEXT NOT NULL DEFAULT 'pending',
    resolved_by    TEXT,
    resolved_at    TEXT,
    consumed_at    TEXT,
    expiry_seconds INTEGER,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_policy_approval_grants_live_key
    ON policy_approval_grants(board_item_id, action, canvas_revision)
    WHERE consumed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_policy_approval_grants_state
    ON policy_approval_grants(state, created_at DESC);

-- D3: persisted, audited spawn switches on the singleton policy workspace.
ALTER TABLE policy_workspace
    ADD COLUMN spawn_requires_live_policy INTEGER NOT NULL DEFAULT 1;
ALTER TABLE policy_workspace
    ADD COLUMN spawn_kill_switch INTEGER NOT NULL DEFAULT 0;

-- Retain the one-shot grant consumed by an immediate dispatch until worker
-- startup succeeds, so a pre-start failure can atomically restore it.
ALTER TABLE task_board_dispatch_intents
    ADD COLUMN consumed_approval_grant_id TEXT;

UPDATE schema_meta SET value = '34' WHERE key = 'version';
