ALTER TABLE policy_canvases ADD COLUMN live_document_json TEXT;
ALTER TABLE policy_canvases ADD COLUMN live_updated_at TEXT;

UPDATE schema_meta SET value = '26' WHERE key = 'version';
