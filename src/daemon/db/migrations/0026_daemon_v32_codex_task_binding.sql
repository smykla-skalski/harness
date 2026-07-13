ALTER TABLE codex_runs ADD COLUMN task_id TEXT;
ALTER TABLE codex_runs ADD COLUMN board_item_id TEXT;
ALTER TABLE codex_runs ADD COLUMN workflow_execution_id TEXT;

UPDATE schema_meta SET value = '32' WHERE key = 'version';
