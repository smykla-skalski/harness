ALTER TABLE policy_workspace
    DROP COLUMN enforcement_snapshot_json;

UPDATE schema_meta SET value = '23' WHERE key = 'version';
