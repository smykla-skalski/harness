ALTER TABLE policy_workspace
    ADD COLUMN review_text_paste_dry_run_canvas_deleted INTEGER NOT NULL DEFAULT 0;

ALTER TABLE policy_canvases
    ADD COLUMN is_review_text_paste_dry_run_canvas INTEGER NOT NULL DEFAULT 0;

UPDATE policy_canvases
SET is_review_text_paste_dry_run_canvas = 1
WHERE canvas_id IN (
    SELECT canvas_id
    FROM policy_canvases
    WHERE EXISTS (
        SELECT 1
        FROM json_each(policy_trace_ids_json)
        WHERE value = 'review-text-paste-dry-run-canvas-v1'
    )
    ORDER BY created_at, canvas_id
    LIMIT 1
);

UPDATE schema_meta SET value = '15' WHERE key = 'version';
