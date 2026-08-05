ALTER TABLE policy_workspace
    ADD COLUMN manual_ocr_paste_canvas_deleted INTEGER NOT NULL DEFAULT 0;

ALTER TABLE policy_canvases
    ADD COLUMN is_manual_ocr_paste_canvas INTEGER NOT NULL DEFAULT 0;

UPDATE policy_canvases
   SET is_manual_ocr_paste_canvas = 1
 WHERE canvas_id IN (
     SELECT canvas_id
       FROM policy_canvases
      WHERE EXISTS (
          SELECT 1
            FROM json_each(policy_trace_ids_json)
           WHERE value = 'manual-ocr-paste-canvas-v1'
      )
      ORDER BY created_at, canvas_id
      LIMIT 1
 );

UPDATE schema_meta SET value = '19' WHERE key = 'version';
