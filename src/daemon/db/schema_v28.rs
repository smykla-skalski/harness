use rusqlite::Connection;

use super::{CliError, db_error};

const REMOTE_ACME_CONFIG_DDL: &str =
    include_str!("migrations/0022_daemon_v28_remote_acme_config.sql");
const ADD_REMOTE_ACME_COLUMN_PREFIX: &str = "ALTER TABLE remote_acme_state ADD COLUMN ";

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    for (column, definition) in remote_acme_config_columns()? {
        if remote_acme_state_column_exists(conn, column)? {
            continue;
        }
        conn.execute(
            &format!("ALTER TABLE remote_acme_state ADD COLUMN {column} {definition}"),
            [],
        )
        .map_err(|error| db_error(format!("add remote acme state {column} column: {error}")))?;
    }
    conn.execute(
        "UPDATE schema_meta SET value = '28' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v28: {error}")))
}

fn remote_acme_config_columns() -> Result<Vec<(&'static str, &'static str)>, CliError> {
    let columns = REMOTE_ACME_CONFIG_DDL
        .lines()
        .filter_map(remote_acme_config_column_from_ddl_line)
        .collect::<Vec<_>>();
    if columns.is_empty() {
        return Err(db_error("remote acme v28 migration has no column DDL"));
    }
    Ok(columns)
}

fn remote_acme_config_column_from_ddl_line(
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
