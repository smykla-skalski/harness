use rusqlite::Connection;

use super::{CliError, db_error};

const REMOTE_ACME_CONFIG_COLUMNS: &[(&str, &str)] = &[
    ("domain", "TEXT"),
    ("host", "TEXT"),
    ("https_port", "INTEGER"),
    ("http_port", "INTEGER"),
    ("acme_email", "TEXT"),
    ("acme_challenge", "TEXT"),
    ("acme_dns_provider", "TEXT"),
];

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    for (column, definition) in REMOTE_ACME_CONFIG_COLUMNS {
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
