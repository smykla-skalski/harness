-- The actual runtime is separate from the requested runtime so a report keeps
-- the durable run's resolved provenance across daemon restarts.
ALTER TABLE task_board_ai_review_reports ADD COLUMN actual_runtime TEXT;
