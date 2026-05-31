ALTER TABLE policy_workspace
    ADD COLUMN review_text_paste_dry_run_canvas_deleted INTEGER NOT NULL DEFAULT 0;

ALTER TABLE policy_canvases
    ADD COLUMN is_review_text_paste_dry_run_canvas INTEGER NOT NULL DEFAULT 0;

UPDATE policy_canvases
SET is_review_text_paste_dry_run_canvas = 1
WHERE title = 'Pasted PR approvals (dry run)';

UPDATE schema_meta SET value = '15' WHERE key = 'version';
