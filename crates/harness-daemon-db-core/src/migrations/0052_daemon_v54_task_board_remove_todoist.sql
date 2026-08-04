-- Todoist is gone from the product, so its rows go with it. An item imported
-- from Todoist is deleted outright. An item the board owns that was only
-- mirrored there keeps its row and loses the Todoist records alone, because
-- deleting it would take work nobody asked to lose.
--
-- The order is foreign-key order: every RESTRICT child of task_board_items has
-- to be gone before the item row is. The CASCADE children (external refs, sync
-- conflicts, dispatch intents, workflow executions) ride along with the delete.

DELETE FROM task_board_dispatch_admission_ledger
WHERE item_id IN (
    SELECT item_id FROM task_board_items WHERE imported_from_provider = 'todoist'
);

DELETE FROM task_board_dispatch_admission_decisions
WHERE item_id IN (
    SELECT item_id FROM task_board_items WHERE imported_from_provider = 'todoist'
);

DELETE FROM task_board_triage_escalations
WHERE item_id IN (
    SELECT item_id FROM task_board_items WHERE imported_from_provider = 'todoist'
);

DELETE FROM task_board_triage_decisions
WHERE item_id IN (
    SELECT item_id FROM task_board_items WHERE imported_from_provider = 'todoist'
);

DELETE FROM task_board_external_create_intents
WHERE provider = 'todoist'
   OR item_id IN (
       SELECT item_id FROM task_board_items WHERE imported_from_provider = 'todoist'
   );

DELETE FROM task_board_items WHERE imported_from_provider = 'todoist';

-- Provenance that outlived its item because the item was board-owned. The
-- decoder behind these columns has no Todoist variant left, so a row surviving
-- here would fail to parse and take the whole item load down with it.
DELETE FROM task_board_external_refs WHERE provider = 'todoist';
DELETE FROM task_board_sync_conflicts WHERE provider = 'todoist';
DELETE FROM task_board_provider_scope_state WHERE provider = 'todoist';

-- Detaching first is what lets the project rows go: task_board_items
-- references task_board_projects with no delete action. A detached item reads
-- as unattributed until its next write re-registers it under a source that
-- still exists.
UPDATE task_board_items
SET source_project_id = NULL
WHERE source_project_id IN (
    SELECT project_id FROM task_board_projects WHERE source = 'todoist'
);

DELETE FROM task_board_projects WHERE source = 'todoist';
