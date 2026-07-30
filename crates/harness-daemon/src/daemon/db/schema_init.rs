use super::{
    CREATE_SCHEMA, CliError, Connection, Duration, ErrorCode, Instant, db_error, test_support,
    thread,
};

pub(super) fn schema_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_meta'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check schema_meta existence: {error}")))
}

pub(super) fn create_schema(conn: &Connection) -> Result<(), CliError> {
    emit_schema_init_info();
    test_support::run_schema_init_hook();
    conn.execute_batch(CREATE_SCHEMA)
        .map_err(|error| db_error(format!("create daemon database schema: {error}")))
}

pub(super) fn reclaim_unused_pages(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        .map_err(|error| db_error(format!("reclaim unused database pages: {error}")))
}

/// Manual tracing event dispatch. The `info!` macro has inherent cognitive
/// complexity of 8 due to its internal expansion (tokio-rs/tracing#553),
/// which exceeds the pedantic threshold of 7.
fn emit_schema_init_info() {
    use tracing::callsite::DefaultCallsite;
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata, callsite::Identifier};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "info",
        "harness::daemon::db",
        Level::INFO,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, Identifier(&CALLSITE)),
        Kind::EVENT,
    );

    let message = "initializing daemon database schema";
    let values: &[Option<&dyn Value>] = &[Some(&message)];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}

pub(super) fn parse_and_check_schema_version(version: &str) -> Result<u8, CliError> {
    let version_number = version.parse::<u8>().map_err(|error| {
        db_error(format!(
            "invalid daemon database schema version '{version}': {error}"
        ))
    })?;
    let expected_version = crate::daemon::db::SCHEMA_VERSION
        .parse::<u8>()
        .map_err(|error| {
            db_error(format!(
                "invalid compiled daemon database schema version '{}': {error}",
                crate::daemon::db::SCHEMA_VERSION
            ))
        })?;
    if version_number > expected_version {
        return Err(db_error(format!(
            "daemon database schema version '{version}' is newer than expected '{}'; downgrade is not supported",
            crate::daemon::db::SCHEMA_VERSION
        )));
    }
    Ok(version_number)
}

pub(super) fn apply_pragmas(conn: &Connection) -> Result<(), CliError> {
    conn.busy_timeout(Duration::from_secs(5))
        .map_err(|error| db_error(format!("set database busy timeout: {error}")))?;
    configure_journal_mode(conn)?;
    conn.execute_batch(
        "PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;
         PRAGMA cache_size = -8000;",
    )
    .map_err(|error| db_error(format!("set database pragmas: {error}")))
}

fn configure_journal_mode(conn: &Connection) -> Result<(), CliError> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match conn.query_row("PRAGMA journal_mode = WAL", [], |row| {
            row.get::<_, String>(0)
        }) {
            Ok(_) => return Ok(()),
            Err(error) if pragma_error_is_retryable(&error) && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(db_error(format!("set database journal mode: {error}"))),
        }
    }
}

fn pragma_error_is_retryable(error: &rusqlite::Error) -> bool {
    matches!(
        error.sqlite_error_code(),
        Some(ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
    )
}
