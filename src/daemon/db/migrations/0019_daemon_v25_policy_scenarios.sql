ALTER TABLE policy_workspace ADD COLUMN scenarios_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE policy_workspace ADD COLUMN scenarios_seeded INTEGER NOT NULL DEFAULT 0;

UPDATE schema_meta SET value = '25' WHERE key = 'version';
