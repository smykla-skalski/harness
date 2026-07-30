-- Existing reports predate separate provenance and used their `runtime` field
-- for both meanings. This replayable backfill preserves that meaning.
UPDATE task_board_ai_review_reports
SET requested_runtime = runtime,
    actual_runtime = runtime
WHERE requested_runtime IS NULL;

UPDATE schema_meta SET value = '60' WHERE key = 'version';
