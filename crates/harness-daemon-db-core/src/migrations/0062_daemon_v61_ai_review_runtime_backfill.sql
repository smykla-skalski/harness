-- Existing reports predate separate provenance and used their `runtime` field
-- for both meanings. This replayable backfill preserves that meaning.
UPDATE task_board_ai_review_reports
SET requested_runtime = runtime,
    actual_runtime = 'codex'
WHERE requested_runtime IS NULL;

UPDATE schema_meta SET value = '61' WHERE key = 'version';
