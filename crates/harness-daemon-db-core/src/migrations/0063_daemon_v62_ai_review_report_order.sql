CREATE TABLE IF NOT EXISTS task_board_ai_review_report_order (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    report_id TEXT NOT NULL UNIQUE
        REFERENCES task_board_ai_review_reports(report_id) ON DELETE CASCADE
);

INSERT OR IGNORE INTO task_board_ai_review_report_order (report_id)
SELECT report_id
FROM task_board_ai_review_reports
ORDER BY finished_at_unix_millis, report_id;

UPDATE schema_meta SET value = '62' WHERE key = 'version';
