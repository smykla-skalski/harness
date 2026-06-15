ALTER TABLE policy_workspace
    ADD COLUMN global_policy_enforcement_enabled INTEGER NOT NULL DEFAULT 1
        CHECK (global_policy_enforcement_enabled IN (0, 1));

UPDATE schema_meta SET value = '22' WHERE key = 'version';
