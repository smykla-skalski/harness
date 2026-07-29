CREATE TABLE IF NOT EXISTS task_board_ai_review_reports (
    report_id TEXT PRIMARY KEY NOT NULL,
    item_id TEXT NOT NULL,
    correlation_id TEXT NOT NULL,
    repository TEXT NOT NULL,
    pull_request_number INTEGER NOT NULL CHECK (pull_request_number > 0),
    head_revision TEXT NOT NULL,
    runtime TEXT NOT NULL,
    requested_model TEXT NOT NULL,
    effective_model TEXT,
    status TEXT NOT NULL CHECK (status IN ('completed', 'failed', 'cancelled')),
    summary TEXT,
    findings_json TEXT NOT NULL,
    partial_output TEXT,
    terminal_reason TEXT,
    started_at TEXT NOT NULL,
    finished_at TEXT NOT NULL,
    finished_at_unix_millis INTEGER NOT NULL,
    UNIQUE (runtime, correlation_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS task_board_ai_review_reports_item_finished
    ON task_board_ai_review_reports(item_id, finished_at_unix_millis DESC, report_id DESC);

UPDATE schema_meta SET value = '58' WHERE key = 'version';
