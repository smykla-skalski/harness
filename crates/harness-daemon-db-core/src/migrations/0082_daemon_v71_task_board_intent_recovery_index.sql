CREATE INDEX IF NOT EXISTS idx_task_board_dispatch_intents_recovery
    ON task_board_dispatch_intents(item_id, work_item_id, status);

UPDATE schema_meta SET value = '71' WHERE key = 'version';
