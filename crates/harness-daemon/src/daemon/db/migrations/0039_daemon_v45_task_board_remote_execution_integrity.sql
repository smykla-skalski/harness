-- Preserve terminal settlement evidence and support the controller's durable
-- offered-at scan order without altering the shipped v43 migration.
CREATE INDEX task_board_remote_assignments_controller_scan
    ON task_board_remote_assignments(offered_at, assignment_id);

CREATE TRIGGER task_board_remote_assignments_preserve_settlement_receipts
BEFORE DELETE ON task_board_remote_assignments
WHEN EXISTS (
    SELECT 1
    FROM task_board_remote_settlement_receipts
    WHERE assignment_id = OLD.assignment_id
      AND fencing_epoch = OLD.fencing_epoch
)
BEGIN
    SELECT RAISE(ABORT, 'cannot delete remote assignment with immutable settlement receipt');
END;

UPDATE schema_meta SET value = '45' WHERE key = 'version';
