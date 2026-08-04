ALTER TABLE task_board_dispatch_intents RENAME TO task_board_dispatch_intents_v32;

CREATE TABLE task_board_dispatch_intents (
    intent_id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES task_board_items(item_id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    work_item_id TEXT NOT NULL,
    workflow_execution_id TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'preparing', 'preparing_claimed', 'held', 'pending', 'starting', 'completed', 'failed'
    )),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at TEXT NOT NULL,
    claim_token TEXT,
    claimed_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT,
    CHECK (
        (status IN ('preparing_claimed', 'starting')
            AND claim_token IS NOT NULL AND claimed_at IS NOT NULL)
        OR
        (status NOT IN ('preparing_claimed', 'starting')
            AND claim_token IS NULL AND claimed_at IS NULL)
    ),
    CHECK (
        (status IN ('completed', 'failed') AND completed_at IS NOT NULL)
        OR
        (status NOT IN ('completed', 'failed') AND completed_at IS NULL)
    )
);

INSERT INTO task_board_dispatch_intents (
    intent_id, item_id, session_id, work_item_id, workflow_execution_id, payload_json,
    status, attempts, available_at, claim_token, claimed_at, last_error,
    created_at, updated_at, completed_at
)
SELECT intent_id, item_id, session_id, work_item_id, workflow_execution_id, payload_json,
       status, attempts, available_at, claim_token, claimed_at, last_error,
       created_at, updated_at, completed_at
FROM task_board_dispatch_intents_v32;

DROP TABLE task_board_dispatch_intents_v32;

CREATE INDEX idx_task_board_dispatch_intents_pending
    ON task_board_dispatch_intents(status, available_at, updated_at);
CREATE UNIQUE INDEX idx_task_board_dispatch_session_work_item
    ON task_board_dispatch_intents(session_id, work_item_id);
CREATE UNIQUE INDEX idx_task_board_dispatch_active_item
    ON task_board_dispatch_intents(item_id)
    WHERE status IN ('preparing', 'preparing_claimed', 'held', 'pending', 'starting');

UPDATE schema_meta SET value = '33' WHERE key = 'version';
