ALTER TABLE task_board_items ADD COLUMN parent_item_id TEXT;
ALTER TABLE task_board_items ADD COLUMN child_order INTEGER NOT NULL DEFAULT 0;

CREATE INDEX task_board_items_parent
    ON task_board_items(parent_item_id, child_order);

UPDATE schema_meta SET value = '41' WHERE key = 'version';
