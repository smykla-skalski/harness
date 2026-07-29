-- Durable ledger of pull request actions, keyed by a stable idempotency id so a
-- repeated intent can never become a second visible action. The PRIMARY KEY
-- serializes admission per id the way `begin_action` requires, mirroring the
-- task-board dispatch ledger.
--
-- IF NOT EXISTS keeps the statement safe under the sync repair replay, which
-- re-runs every migration step against an already-current database.
CREATE TABLE IF NOT EXISTS pull_request_actions (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    repository TEXT NOT NULL,
    number INTEGER NOT NULL,
    url TEXT,
    head_revision TEXT NOT NULL,
    state TEXT NOT NULL,
    failure_class TEXT,
    detail TEXT,
    updated_at TEXT NOT NULL
);

-- Both migration paths take the stamp from here: the async bootstrap trusts
-- this value rather than re-deriving it, and the sync step is this file alone.
UPDATE schema_meta SET value = '57' WHERE key = 'version';
