-- The credential the panel authenticates to the daemon with, claimed once from
-- a one-time pairing code and kept because every mint needs it again.
--
-- The token is stored as the daemon issued it. Unlike a session token, the
-- panel has to replay this one, so a hash would be useless.
--
-- That makes this database credential-bearing, which it was not before: the
-- sessions beside it are only SHA-256 hashes, so a copy of them is not a set of
-- working sessions, while a copy of this row mints pairing links for any
-- identity its holder names. What protects it is the state directory, created
-- 0700 and owned by the service user. Treat a backup of this file as a secret,
-- and revoke the panel's client on the daemon if one leaks.
--
-- One row, enforced by the CHECK, because the panel talks to one daemon.
-- Re-pairing replaces it rather than adding a second.
CREATE TABLE daemon_credential (
    id         INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
    client_id  TEXT    NOT NULL,
    token      TEXT    NOT NULL,
    role       TEXT    NOT NULL,
    claimed_at INTEGER NOT NULL
);
