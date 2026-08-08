-- Durable worker progress for dispatched task-board work items.
--
-- Progress used to live in a Session task the board mirrored. These tables own
-- it instead: one row per work item plus its append-only checkpoint log, so a
-- sessionless dispatch has somewhere to report and the board stays the single
-- authority for what a worker is doing.

CREATE TABLE IF NOT EXISTS task_board_work_item_progress (
    work_item_id     TEXT PRIMARY KEY,
    item_id          TEXT NOT NULL REFERENCES task_board_items(item_id) ON DELETE CASCADE,
    execution_id     TEXT,
    state            TEXT NOT NULL CHECK (state IN (
                         'pending', 'running', 'awaiting_review', 'in_review',
                         'changes_requested', 'blocked', 'done')),
    progress_percent INTEGER CHECK (
                         progress_percent IS NULL
                         OR (progress_percent >= 0 AND progress_percent <= 100)),
    summary          TEXT,
    blocked_reason   TEXT,
    attempt_id       TEXT,
    item_revision    INTEGER CHECK (item_revision IS NULL OR item_revision > 0),
    -- Monotonic fence. A report that does not advance it is refused, which is
    -- what keeps a duplicated or reordered delivery from moving the work item.
    report_sequence  INTEGER NOT NULL DEFAULT 0 CHECK (report_sequence >= 0),
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL,
    completed_at     TEXT,
    CHECK ((state IN ('blocked', 'done')) = (completed_at IS NOT NULL))
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_task_board_work_item_progress_item
    ON task_board_work_item_progress(item_id);
CREATE INDEX IF NOT EXISTS idx_task_board_work_item_progress_execution
    ON task_board_work_item_progress(execution_id);

CREATE TABLE IF NOT EXISTS task_board_work_item_checkpoints (
    work_item_id     TEXT NOT NULL REFERENCES task_board_work_item_progress(work_item_id)
                         ON DELETE CASCADE,
    sequence         INTEGER NOT NULL CHECK (sequence > 0),
    checkpoint_id    TEXT NOT NULL UNIQUE,
    actor            TEXT NOT NULL,
    summary          TEXT NOT NULL,
    progress_percent INTEGER CHECK (
                         progress_percent IS NULL
                         OR (progress_percent >= 0 AND progress_percent <= 100)),
    attempt_id       TEXT,
    recorded_at      TEXT NOT NULL,
    PRIMARY KEY (work_item_id, sequence)
) WITHOUT ROWID;

-- Seed one record per already-dispatched item from the lane it currently
-- shows, so an upgraded board reports the same progress it did before rather
-- than resetting every running item to pending. `INSERT OR IGNORE` keeps the
-- statement replayable and never overwrites a record a worker has since moved.
INSERT OR IGNORE INTO task_board_work_item_progress (
    work_item_id, item_id, execution_id, state, summary, blocked_reason,
    item_revision, report_sequence, created_at, updated_at, completed_at
)
SELECT
    items.work_item_id,
    items.item_id,
    json_extract(items.workflow_json, '$.execution_id'),
    CASE items.status
        WHEN 'done' THEN 'done'
        WHEN 'failed' THEN 'blocked'
        WHEN 'to_review' THEN 'awaiting_review'
        WHEN 'in_review' THEN 'in_review'
        WHEN 'in_progress' THEN
            CASE json_extract(items.workflow_json, '$.current_step_id')
                WHEN 'awaiting_delivery' THEN 'pending'
                WHEN 'worker_pending' THEN 'pending'
                ELSE 'running'
            END
        ELSE 'pending'
    END,
    NULL,
    json_extract(items.workflow_json, '$.last_error'),
    items.revision,
    0,
    items.created_at,
    items.updated_at,
    CASE WHEN items.status IN ('done', 'failed') THEN items.updated_at END
FROM task_board_items AS items
WHERE items.work_item_id IS NOT NULL
  AND items.deleted_at IS NULL;

UPDATE schema_meta SET value = '69' WHERE key = 'version';
