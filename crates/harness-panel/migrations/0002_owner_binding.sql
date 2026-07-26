-- The owner is pinned to the provider's immutable subject id, for the same
-- reason accounts are. `--owner-login` only decides who the binding is taken
-- from the first time someone matching it signs in; after that the login can be
-- renamed and re-registered by anyone without carrying ownership with it.
--
-- One row, enforced by the CHECK, so "who owns this panel" has a single answer.
-- Re-pointing the panel at a different owner means deleting this row.
CREATE TABLE owner_binding (
    id         INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
    provider   TEXT    NOT NULL,
    subject_id TEXT    NOT NULL,
    login      TEXT    NOT NULL,
    bound_at   INTEGER NOT NULL
);
