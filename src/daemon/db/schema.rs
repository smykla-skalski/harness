use super::schema_sql::CREATE_SCHEMA;
use super::{CliError, Connection, DaemonDb, Path, db_error};
use rusqlite::ffi::ErrorCode;
use rusqlite::{Transaction, TransactionBehavior};
use std::cell::RefCell;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(test)]
use std::sync::{Arc, Mutex};

#[cfg(test)]
type SchemaInitHook = dyn Fn() + Send + Sync + 'static;

#[cfg(test)]
static SCHEMA_INIT_HOOK: Mutex<Option<Arc<SchemaInitHook>>> = Mutex::new(None);

impl DaemonDb {
    /// Open the daemon database at `path`, applying pragmas and running any
    /// pending schema migrations.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn open(path: &Path) -> Result<Self, CliError> {
        let conn = Connection::open(path)
            .map_err(|error| db_error(format!("open daemon database: {error}")))?;
        apply_pragmas(&conn)?;
        let db = Self {
            conn,
            path: Some(path.to_path_buf()),
            activity_fold: RefCell::new(super::activity_fold::ActivityFoldCache::new()),
        };
        db.ensure_schema()?;
        Ok(db)
    }

    /// Open an in-memory database for testing.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    #[cfg(test)]
    pub fn open_in_memory() -> Result<Self, CliError> {
        let conn = Connection::open_in_memory()
            .map_err(|error| db_error(format!("open in-memory database: {error}")))?;
        apply_pragmas(&conn)?;
        let db = Self {
            conn,
            path: None,
            activity_fold: RefCell::new(super::activity_fold::ActivityFoldCache::new()),
        };
        db.ensure_schema()?;
        Ok(db)
    }

    /// Return the current schema version stored in `schema_meta`.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn schema_version(&self) -> Result<String, CliError> {
        super::trace_sync_db_operation("schema_version", "read", self.path.as_deref(), || {
            self.conn
                .query_row(
                    "SELECT value FROM schema_meta WHERE key = 'version'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| db_error(format!("read schema version: {error}")))
        })
    }

    /// Return the raw connection for advanced queries. Prefer typed methods
    /// on [`DaemonDb`] over direct connection access.
    #[must_use]
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    fn ensure_schema(&self) -> Result<(), CliError> {
        let transaction = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)
            .map_err(|error| db_error(format!("begin schema bootstrap transaction: {error}")))?;
        if !schema_exists(&transaction)? {
            create_schema(&transaction)?;
        }
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit schema bootstrap transaction: {error}")))?;
        self.run_migrations()
    }

    fn run_migrations(&self) -> Result<(), CliError> {
        let version = self.schema_version()?;
        let should_reclaim_space =
            super::schema_migrations::run_pre_v7_migrations(&self.conn, version.as_str())?;
        self.run_post_v7_migrations(version.as_str())?;
        super::schema_repairs::repair_current_schema_shape(self)?;
        if should_reclaim_space {
            reclaim_unused_pages(&self.conn)?;
        }
        super::schema_repairs::repair_noncanonical_session_state_wire(self)?;
        Ok(())
    }

    fn run_post_v7_migrations(&self, version: &str) -> Result<(), CliError> {
        self.apply_pending_migrations(parse_and_check_schema_version(version)?)
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "sequential migration chain has one if-guard per schema version step"
    )]
    fn apply_pending_migrations(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 7 {
            self.migrate_v7_to_v8()?;
        }
        if version_number <= 8 {
            self.migrate_v8_to_v9()?;
        }
        if version_number <= 9 {
            self.migrate_v9_to_v10()?;
        }
        if version_number <= 10 {
            self.migrate_v10_to_v11()?;
        }
        if version_number <= 11 {
            self.migrate_v11_to_v12()?;
        }
        if version_number <= 12 {
            self.migrate_v12_to_v13()?;
        }
        if version_number <= 13 {
            self.migrate_v13_to_v14()?;
        }
        if version_number <= 14 {
            self.migrate_v14_to_v15()?;
        }
        if version_number <= 15 {
            self.migrate_v15_to_v16()?;
        }
        if version_number <= 16 {
            self.migrate_v16_to_v17()?;
        }
        if version_number <= 17 {
            self.migrate_v17_to_v18()?;
        }
        if version_number <= 18 {
            self.migrate_v18_to_v19()?;
        }
        if version_number <= 19 {
            self.migrate_v19_to_v20()?;
        }
        if version_number <= 20 {
            self.migrate_v20_to_v21()?;
        }
        if version_number <= 21 {
            self.migrate_v21_to_v22()?;
        }
        if version_number <= 22 {
            self.migrate_v22_to_v23()?;
        }
        Ok(())
    }

    fn migrate_v7_to_v8(&self) -> Result<(), CliError> {
        // v7 databases created before the backfill shipped have empty ledger
        // rows even when the legacy source tables still hold conversation
        // history. Rebuild every session's ledger, then stamp v8 so the
        // upgrade is one-shot and idempotent across restarts.
        self.backfill_legacy_timelines()?;
        self.conn
            .execute(
                "UPDATE schema_meta SET value = '8' WHERE key = 'version'",
                [],
            )
            .map_err(|error| db_error(format!("bump schema version to v8: {error}")))?;
        Ok(())
    }

    fn migrate_v8_to_v9(&self) -> Result<(), CliError> {
        super::schema_repairs::repair_stale_active_sessions_without_leader(self)?;
        self.conn
            .execute(
                "UPDATE schema_meta SET value = '9' WHERE key = 'version'",
                [],
            )
            .map_err(|error| db_error(format!("bump schema version to v9: {error}")))?;
        Ok(())
    }

    fn migrate_v9_to_v10(&self) -> Result<(), CliError> {
        super::schema_v10::run(&self.conn)
    }

    fn migrate_v10_to_v11(&self) -> Result<(), CliError> {
        super::schema_v11::run(&self.conn)
    }

    fn migrate_v11_to_v12(&self) -> Result<(), CliError> {
        super::schema_v12::run(&self.conn)
    }

    fn migrate_v12_to_v13(&self) -> Result<(), CliError> {
        super::schema_v13::run(&self.conn)
    }

    fn migrate_v13_to_v14(&self) -> Result<(), CliError> {
        super::schema_v14::run(&self.conn)
    }

    fn migrate_v14_to_v15(&self) -> Result<(), CliError> {
        super::schema_v15::run(&self.conn)
    }

    fn migrate_v15_to_v16(&self) -> Result<(), CliError> {
        super::schema_v16::run(&self.conn)
    }

    fn migrate_v16_to_v17(&self) -> Result<(), CliError> {
        super::schema_v17::run(&self.conn)
    }

    fn migrate_v17_to_v18(&self) -> Result<(), CliError> {
        super::schema_v18::run(&self.conn)
    }

    fn migrate_v18_to_v19(&self) -> Result<(), CliError> {
        super::schema_v19::run(&self.conn)
    }

    fn migrate_v19_to_v20(&self) -> Result<(), CliError> {
        super::schema_v20::run(&self.conn)
    }

    fn migrate_v20_to_v21(&self) -> Result<(), CliError> {
        super::schema_v21::run(&self.conn)
    }

    fn migrate_v21_to_v22(&self) -> Result<(), CliError> {
        super::schema_v22::run(&self.conn)
    }

    fn migrate_v22_to_v23(&self) -> Result<(), CliError> {
        super::schema_v23::run(&self.conn)
    }
}

fn schema_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_meta'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check schema_meta existence: {error}")))
}

fn create_schema(conn: &Connection) -> Result<(), CliError> {
    emit_schema_init_info();
    run_schema_init_hook();
    conn.execute_batch(CREATE_SCHEMA)
        .map_err(|error| db_error(format!("create daemon database schema: {error}")))
}

#[cfg(test)]
pub(crate) fn set_schema_init_hook(hook: Option<Arc<SchemaInitHook>>) {
    *SCHEMA_INIT_HOOK
        .lock()
        .expect("schema init hook mutex poisoned") = hook;
}

fn run_schema_init_hook() {
    #[cfg(test)]
    if let Some(hook) = SCHEMA_INIT_HOOK
        .lock()
        .expect("schema init hook mutex poisoned")
        .clone()
    {
        hook();
    }
}

fn reclaim_unused_pages(conn: &Connection) -> Result<(), CliError> {
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

fn parse_and_check_schema_version(version: &str) -> Result<u8, CliError> {
    let version_number = version.parse::<u8>().map_err(|error| {
        db_error(format!(
            "invalid daemon database schema version '{version}': {error}"
        ))
    })?;
    let expected_version = super::SCHEMA_VERSION.parse::<u8>().map_err(|error| {
        db_error(format!(
            "invalid compiled daemon database schema version '{}': {error}",
            super::SCHEMA_VERSION
        ))
    })?;
    if version_number > expected_version {
        return Err(db_error(format!(
            "daemon database schema version '{version}' is newer than expected '{}'; downgrade is not supported",
            super::SCHEMA_VERSION
        )));
    }
    Ok(version_number)
}

fn apply_pragmas(conn: &Connection) -> Result<(), CliError> {
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
