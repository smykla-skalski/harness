use rusqlite::Connection;

use super::CliError;

const PAIR_MANAGE_BACKFILL_SQL: &str =
    include_str!("migrations/0054_daemon_v55_pair_manage_backfill.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    // Safe to repeat: both statements skip a client that already holds the
    // scope, because a set carrying it no longer matches the old default the
    // guards require. The file carries the version stamp in the same batch, as
    // the backfill migrations before it do, so a stamp here would report a
    // failure over work that had already landed.
    conn.execute_batch(PAIR_MANAGE_BACKFILL_SQL)
        .map_err(|error| super::db_error(format!("backfill schema v55 pair_manage: {error}")))
}

#[cfg(test)]
#[path = "schema_v55_tests.rs"]
mod tests;
