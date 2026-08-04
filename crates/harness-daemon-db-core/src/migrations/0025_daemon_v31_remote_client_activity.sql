CREATE TRIGGER IF NOT EXISTS remote_audit_events_touch_client_activity
AFTER INSERT ON remote_audit_events
WHEN NEW.request_id IS NOT NULL AND NEW.client_id IS NOT NULL
BEGIN
    UPDATE remote_clients
    SET last_seen_at = NEW.recorded_at
    WHERE client_id = NEW.client_id
      AND revoked_at IS NULL
      AND (last_seen_at IS NULL OR last_seen_at < NEW.recorded_at);
END;

UPDATE schema_meta SET value = '31' WHERE key = 'version';
