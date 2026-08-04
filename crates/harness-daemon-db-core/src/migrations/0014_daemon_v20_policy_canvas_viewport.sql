ALTER TABLE policy_canvases
    ADD COLUMN layout_zoom REAL NOT NULL DEFAULT 1.0;

ALTER TABLE policy_canvases
    ADD COLUMN layout_offset_x INTEGER NOT NULL DEFAULT 0;

ALTER TABLE policy_canvases
    ADD COLUMN layout_offset_y INTEGER NOT NULL DEFAULT 0;

UPDATE schema_meta SET value = '20' WHERE key = 'version';
