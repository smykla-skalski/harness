ALTER TABLE policy_nodes
    ADD COLUMN layout_source TEXT CHECK (
        layout_source IS NULL OR layout_source IN ('auto', 'manual')
    );

UPDATE schema_meta SET value = '21' WHERE key = 'version';
