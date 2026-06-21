CREATE TABLE IF NOT EXISTS remote_clients (
    client_id     TEXT PRIMARY KEY,
    display_name  TEXT NOT NULL,
    platform      TEXT NOT NULL,
    role          TEXT NOT NULL,
    scopes_json   TEXT NOT NULL,
    token_hash    TEXT NOT NULL,
    token_hint    TEXT NOT NULL,
    created_at    TEXT NOT NULL,
    last_seen_at  TEXT,
    revoked_at    TEXT,
    rotated_at    TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}'
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_remote_clients_token_hash
    ON remote_clients(token_hash);
CREATE INDEX IF NOT EXISTS idx_remote_clients_role
    ON remote_clients(role);
CREATE INDEX IF NOT EXISTS idx_remote_clients_revoked
    ON remote_clients(revoked_at);

CREATE TABLE IF NOT EXISTS remote_pairing_codes (
    pairing_id       TEXT PRIMARY KEY,
    code_hash        TEXT NOT NULL UNIQUE,
    role             TEXT NOT NULL,
    scopes_json      TEXT NOT NULL,
    created_at       TEXT NOT NULL,
    expires_at       TEXT NOT NULL,
    claimed_at       TEXT,
    claimed_client_id TEXT REFERENCES remote_clients(client_id),
    claim_remote_addr TEXT,
    metadata_json    TEXT NOT NULL DEFAULT '{}'
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_remote_pairing_codes_expiry
    ON remote_pairing_codes(expires_at, claimed_at);

CREATE TABLE IF NOT EXISTS remote_audit_events (
    event_id        TEXT PRIMARY KEY,
    recorded_at     TEXT NOT NULL,
    request_id      TEXT,
    client_id       TEXT,
    route_or_method TEXT NOT NULL,
    scope           TEXT NOT NULL,
    scope_decision  TEXT NOT NULL,
    outcome         TEXT NOT NULL,
    remote_addr     TEXT,
    error_detail    TEXT,
    metadata_json   TEXT NOT NULL DEFAULT '{}'
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_remote_audit_events_recorded
    ON remote_audit_events(recorded_at DESC, event_id DESC);
CREATE INDEX IF NOT EXISTS idx_remote_audit_events_client
    ON remote_audit_events(client_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_remote_audit_events_route
    ON remote_audit_events(route_or_method, recorded_at DESC);

CREATE TABLE IF NOT EXISTS remote_acme_state (
    singleton               INTEGER PRIMARY KEY CHECK (singleton = 1),
    account_id              TEXT,
    certificate_pem         TEXT,
    private_key_pem         TEXT,
    certificate_fingerprint TEXT,
    renewal_status          TEXT NOT NULL DEFAULT 'unknown',
    renewal_error           TEXT,
    updated_at              TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO remote_acme_state (singleton, updated_at)
VALUES (1, datetime('now'))
ON CONFLICT(singleton) DO NOTHING;

UPDATE schema_meta SET value = '27' WHERE key = 'version';
