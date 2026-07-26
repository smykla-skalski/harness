-- Accounts are keyed on the provider's immutable subject id rather than the
-- login, because a GitHub login can be renamed and then claimed by someone
-- else. The login is kept as a label an operator can recognise.
CREATE TABLE accounts (
    id            TEXT    NOT NULL PRIMARY KEY,
    provider      TEXT    NOT NULL,
    subject_id    TEXT    NOT NULL,
    login         TEXT    NOT NULL,
    display_name  TEXT    NOT NULL,
    avatar_url    TEXT,
    first_seen_at INTEGER NOT NULL,
    last_seen_at  INTEGER NOT NULL,
    UNIQUE (provider, subject_id)
);

-- Only the SHA-256 of a session token is stored, so a copy of this database is
-- not a set of working sessions.
CREATE TABLE sessions (
    token_hash TEXT    NOT NULL PRIMARY KEY,
    account_id TEXT    NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX sessions_expires_at ON sessions (expires_at);
CREATE INDEX sessions_account_id ON sessions (account_id);

-- One row per sign-in that has started and not yet come back. Consuming a row
-- is a delete, which is what makes an authorization code replay fail.
CREATE TABLE oauth_states (
    state_hash TEXT    NOT NULL PRIMARY KEY,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX oauth_states_expires_at ON oauth_states (expires_at);
