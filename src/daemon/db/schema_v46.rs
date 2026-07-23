use rusqlite::Connection;

use super::CliError;

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    super::schema_repairs_triage::repair_and_stamp(conn)?;
    conn.execute(
        "UPDATE schema_meta SET value = '46' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| super::db_error(format!("stamp schema v46: {error}")))
}

#[cfg(test)]
#[path = "schema_v46_tests.rs"]
mod tests;
