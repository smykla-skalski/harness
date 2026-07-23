use rusqlite::Connection;

use super::CliError;

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    super::schema_repairs_remote_execution_v45::repair_and_stamp(conn)
}

#[cfg(test)]
#[path = "schema_v45_tests.rs"]
mod tests;
