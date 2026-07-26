-- What the panel remembers about a link it minted: enough to answer "did I
-- issue this, for whom, and when does it lapse", and nothing more.
--
-- The link itself is deliberately absent. It carries a one-time code, so
-- storing it would turn this table into a set of usable credentials for
-- everyone who has ever generated one. The person sees it once, when it is
-- minted, and the daemon holds the only lasting record.
CREATE TABLE pair_links (
    id         TEXT    NOT NULL PRIMARY KEY,
    account_id TEXT    NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    role       TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX pair_links_account_id ON pair_links (account_id, created_at);

-- The cap is checked on every generate, and it asks how many of one account's
-- links have not expired. Nothing prunes this table, because the rows are what
-- an operator reconciles against the daemon, so without this the check reads
-- every link that account has ever been issued.
CREATE INDEX pair_links_account_expiry ON pair_links (account_id, expires_at);
