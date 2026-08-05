ALTER TABLE agent_turn_runs ADD COLUMN runtime_turn_id TEXT;

UPDATE schema_meta SET value = '60' WHERE key = 'version';
