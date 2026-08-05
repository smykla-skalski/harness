CREATE TABLE IF NOT EXISTS task_board_reconciliation_cursors (
    queue TEXT PRIMARY KEY,
    sort_updated_at TEXT NOT NULL,
    sort_execution_id TEXT NOT NULL
) WITHOUT ROWID;

UPDATE schema_meta SET value = '40' WHERE key = 'version';
