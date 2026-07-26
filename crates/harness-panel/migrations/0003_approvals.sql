-- Nobody can pair until the owner says so, which is why the column defaults to
-- 0: an account that appears between a deploy and the owner's next visit is not
-- quietly able to mint links.
ALTER TABLE accounts ADD COLUMN can_pair INTEGER NOT NULL DEFAULT 0;

-- One row per decision, kept after the fact so an operator can answer who
-- allowed a person to pair and when. Append-only: `accounts.can_pair` is the
-- current answer and this is the trail that explains it.
--
-- The actor's login is stored alongside their id because it is a label for a
-- human reading the trail later, and the id it belonged to may have been
-- renamed by then.
CREATE TABLE approval_events (
    id          TEXT    NOT NULL PRIMARY KEY,
    account_id  TEXT    NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    actor_id    TEXT    NOT NULL,
    actor_login TEXT    NOT NULL,
    granted     INTEGER NOT NULL,
    decided_at  INTEGER NOT NULL
);

CREATE INDEX approval_events_account_id ON approval_events (account_id, decided_at);
