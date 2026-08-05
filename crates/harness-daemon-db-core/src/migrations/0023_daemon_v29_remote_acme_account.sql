ALTER TABLE remote_acme_state ADD COLUMN account_credentials_json TEXT;

UPDATE schema_meta SET value = '29' WHERE key = 'version';
