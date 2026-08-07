-- The board item's replacement owners. `session_id` and `work_item_id` stay put
-- so an item dispatched before this migration keeps reading back the way it was
-- written; a fresh dispatch fills these two instead.
ALTER TABLE task_board_items ADD COLUMN workspace_id TEXT;
ALTER TABLE task_board_items ADD COLUMN working_copy_id TEXT;

CREATE INDEX IF NOT EXISTS idx_task_board_items_workspace
    ON task_board_items(workspace_id, working_copy_id);
