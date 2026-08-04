CREATE TABLE IF NOT EXISTS task_board_items (
    item_id TEXT PRIMARY KEY,
    schema_version INTEGER NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    status TEXT NOT NULL,
    priority TEXT NOT NULL,
    tags_json TEXT NOT NULL,
    project_id TEXT,
    target_project_types_json TEXT NOT NULL,
    agent_mode TEXT NOT NULL,
    imported_from_provider TEXT,
    planning_json TEXT NOT NULL,
    workflow_json TEXT NOT NULL,
    session_id TEXT,
    work_item_id TEXT,
    usage_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0)
);

CREATE INDEX IF NOT EXISTS idx_task_board_items_status_updated
    ON task_board_items(status, updated_at DESC, item_id);
CREATE INDEX IF NOT EXISTS idx_task_board_items_project
    ON task_board_items(project_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_task_board_items_session
    ON task_board_items(session_id, work_item_id);

CREATE TABLE IF NOT EXISTS task_board_identity (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    instance_id TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS task_board_external_refs (
    item_id TEXT NOT NULL REFERENCES task_board_items(item_id) ON DELETE CASCADE,
    position INTEGER NOT NULL CHECK (position >= 0),
    provider TEXT NOT NULL,
    external_id TEXT NOT NULL,
    url TEXT,
    sync_state_json TEXT,
    PRIMARY KEY (item_id, position)
);

CREATE INDEX IF NOT EXISTS idx_task_board_external_refs_provider_id
    ON task_board_external_refs(provider, external_id);

CREATE TABLE IF NOT EXISTS task_board_machines (
    machine_id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    project_types_json TEXT NOT NULL,
    agent_modes_json TEXT NOT NULL,
    last_seen TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS task_board_local_machine (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    machine_id TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_board_orchestrator_settings (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    settings_json TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_board_orchestrator_state (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    state_json TEXT NOT NULL,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    running INTEGER NOT NULL CHECK (running IN (0, 1)),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_board_runtime_config (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    config_json TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS policy_workflow_runs (
    run_id TEXT PRIMARY KEY,
    position INTEGER NOT NULL CHECK (position >= 0),
    workflow_id TEXT NOT NULL,
    subject_key TEXT NOT NULL,
    subject_fingerprint TEXT,
    trigger TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'running', 'waiting', 'completed', 'failed', 'cancelled'
    )),
    waiting_since TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT,
    payload_json TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0)
);

CREATE INDEX IF NOT EXISTS idx_policy_workflow_runs_subject
    ON policy_workflow_runs(workflow_id, subject_key, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_policy_workflow_runs_status
    ON policy_workflow_runs(status, updated_at, created_at);

CREATE TABLE IF NOT EXISTS policy_event_inbox (
    event_key TEXT NOT NULL,
    subject_key TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    occurred_at TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    PRIMARY KEY (event_key, subject_key)
);

CREATE INDEX IF NOT EXISTS idx_policy_event_inbox_position
    ON policy_event_inbox(position);

CREATE TABLE IF NOT EXISTS policy_handoff_outbox (
    record_id INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at TEXT NOT NULL,
    payload_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS policy_notification_outbox (
    record_id INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at TEXT NOT NULL,
    payload_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS policy_task_creation_outbox (
    record_id INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at TEXT NOT NULL,
    payload_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_policy_handoff_outbox_recorded
    ON policy_handoff_outbox(recorded_at, record_id);
CREATE INDEX IF NOT EXISTS idx_policy_notification_outbox_recorded
    ON policy_notification_outbox(recorded_at, record_id);
CREATE INDEX IF NOT EXISTS idx_policy_task_creation_outbox_recorded
    ON policy_task_creation_outbox(recorded_at, record_id);

CREATE TABLE IF NOT EXISTS task_board_dispatch_intents (
    intent_id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES task_board_items(item_id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    work_item_id TEXT NOT NULL,
    workflow_execution_id TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'preparing', 'preparing_claimed', 'pending', 'starting', 'completed', 'failed'
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

CREATE INDEX IF NOT EXISTS idx_task_board_dispatch_intents_pending
    ON task_board_dispatch_intents(status, available_at, updated_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_dispatch_session_work_item
    ON task_board_dispatch_intents(session_id, work_item_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_dispatch_active_item
    ON task_board_dispatch_intents(item_id)
    WHERE status IN ('preparing', 'preparing_claimed', 'pending', 'starting');

CREATE TABLE IF NOT EXISTS task_board_imports (
    source_kind TEXT PRIMARY KEY,
    source_digest TEXT NOT NULL,
    canonical_model_digest TEXT NOT NULL,
    source_counts_json TEXT NOT NULL,
    staged_path TEXT,
    imported_at TEXT NOT NULL,
    archived_at TEXT,
    archive_path TEXT,
    secret_handoff_id TEXT,
    secret_handoff_digest TEXT,
    secret_handoff_phase TEXT NOT NULL DEFAULT 'complete'
        CHECK (secret_handoff_phase IN ('pending', 'acknowledging', 'complete')),
    secret_acknowledged_at TEXT
);

UPDATE schema_meta SET value = '30' WHERE key = 'version';
