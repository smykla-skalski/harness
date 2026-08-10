CREATE INDEX IF NOT EXISTS idx_task_board_work_item_progress_recovery
    ON task_board_work_item_progress(item_id, work_item_id, attempt_id)
    WHERE completed_at IS NULL
      AND state IN ('pending', 'running')
      AND attempt_id IS NOT NULL;

UPDATE schema_meta SET value = '70' WHERE key = 'version';
