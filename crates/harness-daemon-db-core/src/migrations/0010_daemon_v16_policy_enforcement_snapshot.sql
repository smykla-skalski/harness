ALTER TABLE policy_workspace
    ADD COLUMN enforcement_snapshot_json TEXT;

UPDATE schema_meta SET value = '16' WHERE key = 'version';
