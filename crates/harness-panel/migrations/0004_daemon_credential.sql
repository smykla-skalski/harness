-- The credential the panel authenticates to the daemon with, claimed once from
-- a one-time pairing code and kept because every mint needs it again.
--
-- The token is stored as the daemon issued it: unlike a session token, the
-- panel has to replay this one, so a hash would be useless. What protects it is
-- the state directory, which is created 0700 and owned by the service user.
-- Anyone who can read this file can already read the sessions beside it.
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
