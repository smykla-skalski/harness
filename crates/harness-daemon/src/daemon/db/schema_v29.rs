use rusqlite::Connection;

use super::{CliError, db_error};

const REMOTE_ACME_ACCOUNT_DDL: &str =
    include_str!("migrations/0023_daemon_v29_remote_acme_account.sql");
const ADD_REMOTE_ACME_COLUMN_PREFIX: &str = "ALTER TABLE remote_acme_state ADD COLUMN ";

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let (column, definition) = remote_acme_account_column()?;
    if !remote_acme_state_column_exists(conn, column)? {
        conn.execute(
            &format!("ALTER TABLE remote_acme_state ADD COLUMN {column} {definition}"),
            [],
        )
        .map_err(|error| db_error(format!("add remote acme state {column} column: {error}")))?;
    }
    conn.execute(
        "UPDATE schema_meta SET value = '29' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v29: {error}")))
}

fn remote_acme_account_column() -> Result<(&'static str, &'static str), CliError> {
    REMOTE_ACME_ACCOUNT_DDL
        .lines()
        .find_map(remote_acme_account_column_from_ddl_line)
        .ok_or_else(|| db_error("remote acme v29 migration has no column DDL"))
}

fn remote_acme_account_column_from_ddl_line(
    line: &'static str,
) -> Option<(&'static str, &'static str)> {
    let statement = line
        .trim()
        .strip_prefix(ADD_REMOTE_ACME_COLUMN_PREFIX)?
        .strip_suffix(';')?;
    statement.split_once(' ')
}

fn remote_acme_state_column_exists(conn: &Connection, column: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('remote_acme_state') WHERE name = ?1",
        [column],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| {
        db_error(format!(
            "inspect remote acme state {column} column: {error}"
        ))
    })
}
