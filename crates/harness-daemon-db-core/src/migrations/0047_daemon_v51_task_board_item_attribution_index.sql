-- Kept apart from the attribution migration so it can run unconditionally.
-- That one only applies once, on the boot that adds the column; a database
-- that later loses this index would never get it back, because the repair
-- chain would find the column already present and stamp the version without
-- rebuilding anything.
CREATE INDEX IF NOT EXISTS task_board_items_source_project
    ON task_board_items(source_project_id, deleted_at);

UPDATE schema_meta SET value = '51' WHERE key = 'version';
