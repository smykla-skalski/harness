-- Keep the established `runtime` column for API and database compatibility
-- while recording explicit requested provenance for new reports.
ALTER TABLE task_board_ai_review_reports ADD COLUMN requested_runtime TEXT;
