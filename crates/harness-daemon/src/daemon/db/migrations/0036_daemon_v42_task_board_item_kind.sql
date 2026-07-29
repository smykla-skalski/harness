ALTER TABLE task_board_items ADD COLUMN kind TEXT NOT NULL DEFAULT 'task';

UPDATE schema_meta SET value = '42' WHERE key = 'version';
