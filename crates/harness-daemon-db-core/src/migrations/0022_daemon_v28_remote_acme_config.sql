ALTER TABLE remote_acme_state ADD COLUMN domain TEXT;
ALTER TABLE remote_acme_state ADD COLUMN host TEXT;
ALTER TABLE remote_acme_state ADD COLUMN https_port INTEGER;
ALTER TABLE remote_acme_state ADD COLUMN http_port INTEGER;
ALTER TABLE remote_acme_state ADD COLUMN acme_email TEXT;
ALTER TABLE remote_acme_state ADD COLUMN acme_challenge TEXT;
ALTER TABLE remote_acme_state ADD COLUMN acme_dns_provider TEXT;

UPDATE schema_meta SET value = '28' WHERE key = 'version';
