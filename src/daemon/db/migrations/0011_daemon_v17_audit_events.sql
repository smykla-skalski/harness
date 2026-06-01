CREATE TABLE IF NOT EXISTS audit_events (
    id                TEXT PRIMARY KEY,
    recorded_at       TEXT NOT NULL,
    source            TEXT NOT NULL,
    category          TEXT NOT NULL,
    kind              TEXT NOT NULL,
    severity          TEXT NOT NULL,
    outcome           TEXT NOT NULL,
    title             TEXT NOT NULL,
    summary           TEXT NOT NULL,
    subject           TEXT,
    actor             TEXT,
    correlation_id    TEXT,
    action_key        TEXT,
    payload_json      TEXT,
    legacy_message    TEXT,
    related_urls_json TEXT NOT NULL DEFAULT '[]'
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_audit_events_recorded_at
    ON audit_events(recorded_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_source
    ON audit_events(source, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_category
    ON audit_events(category, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_severity
    ON audit_events(severity, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_outcome
    ON audit_events(outcome, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_action_key
    ON audit_events(action_key, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_subject
    ON audit_events(subject, recorded_at DESC);

UPDATE schema_meta SET value = '17' WHERE key = 'version';
