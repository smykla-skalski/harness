ALTER TABLE tasks ADD COLUMN deleted_at TEXT;

UPDATE schema_meta SET value = '12' WHERE key = 'version';
