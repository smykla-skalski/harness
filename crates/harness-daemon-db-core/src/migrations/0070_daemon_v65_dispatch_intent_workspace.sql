-- Fresh dispatch reserves a workspace and a working copy instead of a Session,
-- so the intent's `session_id` becomes optional correlation metadata and the
-- CHECK moves the requirement onto "one owner or the other".
--
-- Same `legacy_alter_table` reason as the terminal rebuild: the admission
-- decisions and ledger name `task_board_dispatch_intents` in their foreign
-- keys, and those keys have to keep pointing at the rebuilt table rather than
-- follow the rename to the scratch name this migration drops.
PRAGMA legacy_alter_table = ON;
ALTER TABLE task_board_dispatch_intents RENAME TO task_board_dispatch_intents_v64;
PRAGMA legacy_alter_table = OFF;

CREATE TABLE task_board_dispatch_intents (
    intent_id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES task_board_items(item_id) ON DELETE CASCADE,
    session_id TEXT,
    workspace_id TEXT,
    working_copy_id TEXT,
    work_item_id TEXT NOT NULL,
    workflow_execution_id TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'preparing', 'preparing_claimed', 'held', 'pending', 'workflow_prepared',
        'starting', 'completed', 'failed'
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
    compensation_pending INTEGER NOT NULL DEFAULT 0
        CHECK (
            compensation_pending IN (0, 1)
            AND (
                compensation_pending = 0
                OR (
                    status IN ('pending', 'starting')
                    AND last_error IS NOT NULL
                    AND length(last_error) > 0
                )
            )
        ),
    start_admission_outcome TEXT,
    start_admission_settings_revision INTEGER,
    CHECK (session_id IS NOT NULL OR workspace_id IS NOT NULL),
    CHECK (COALESCE((
        (
            start_admission_outcome IS NULL
            AND start_admission_settings_revision IS NULL
        )
        OR (
            start_admission_outcome = 'unconfigured'
            AND typeof(start_admission_settings_revision) = 'integer'
            AND start_admission_settings_revision > 0
        )
    ), 0)),
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
    ),
    CHECK (
        status != 'workflow_prepared'
        OR (
            length(trim(workflow_execution_id)) > 0
            AND compensation_pending = 0
            AND claim_token IS NULL
            AND claimed_at IS NULL
            AND completed_at IS NULL
        )
    )
);

INSERT INTO task_board_dispatch_intents (
    intent_id, item_id, session_id, workspace_id, working_copy_id, work_item_id,
    workflow_execution_id, payload_json, status, attempts, available_at,
    claim_token, claimed_at, last_error, created_at, updated_at, completed_at,
    consumed_approval_grant_id, compensation_pending, start_admission_outcome,
    start_admission_settings_revision
)
SELECT intent_id, item_id, session_id, NULL, NULL, work_item_id,
       workflow_execution_id, payload_json, status, attempts, available_at,
       claim_token, claimed_at, last_error, created_at, updated_at, completed_at,
       consumed_approval_grant_id, compensation_pending, start_admission_outcome,
       start_admission_settings_revision
FROM task_board_dispatch_intents_v64;

DROP TABLE task_board_dispatch_intents_v64;

CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_intents_admission_identity
    ON task_board_dispatch_intents(intent_id, item_id);
CREATE INDEX IF NOT EXISTS idx_task_board_dispatch_intents_pending
    ON task_board_dispatch_intents(status, available_at, updated_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_dispatch_session_work_item
    ON task_board_dispatch_intents(session_id, work_item_id);
-- The session-keyed index above stops guarding anything once session_id is
-- NULL, because SQLite counts NULLs as distinct. This is the same guarantee for
-- the replacement owner.
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_dispatch_workspace_work_item
    ON task_board_dispatch_intents(workspace_id, work_item_id)
    WHERE workspace_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_dispatch_active_item
    ON task_board_dispatch_intents(item_id)
    WHERE status IN (
        'preparing', 'preparing_claimed', 'held', 'pending',
        'workflow_prepared', 'starting'
    );

UPDATE schema_meta SET value = '65' WHERE key = 'version';
