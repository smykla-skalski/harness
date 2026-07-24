use super::schema_sql::CREATE_SCHEMA;
use super::{CliError, Connection, DaemonDb, Path, db_error};
use rusqlite::ffi::ErrorCode;
use rusqlite::{Transaction, TransactionBehavior};
use std::cell::RefCell;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

#[path = "schema_test_support.rs"]
mod test_support;

#[cfg(test)]
pub(crate) use test_support::set_schema_init_hook;

#[path = "schema_migration_steps.rs"]
mod migration_steps;
use migration_steps::{
    migrate_v9_to_v10, migrate_v10_to_v11, migrate_v11_to_v12, migrate_v12_to_v13,
    migrate_v13_to_v14, migrate_v14_to_v15, migrate_v15_to_v16, migrate_v16_to_v17,
    migrate_v17_to_v18, migrate_v18_to_v19, migrate_v19_to_v20, migrate_v20_to_v21,
    migrate_v21_to_v22, migrate_v22_to_v23, migrate_v23_to_v24, migrate_v24_to_v25,
    migrate_v25_to_v26, migrate_v26_to_v27, migrate_v27_to_v28, migrate_v28_to_v29,
    migrate_v29_to_v30, migrate_v30_to_v31, migrate_v31_to_v32, migrate_v32_to_v33,
    migrate_v33_to_v34, migrate_v34_to_v35, migrate_v35_to_v36, migrate_v36_to_v37,
    migrate_v37_to_v38, migrate_v38_to_v39, migrate_v39_to_v40, migrate_v40_to_v41,
    migrate_v41_to_v42, migrate_v42_to_v43,
};

static SCHEMA_MIGRATION_LOCK: Mutex<()> = Mutex::new(());

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
        db.prune_remote_audit_events()?;
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
        db.prune_remote_audit_events()?;
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
        let _schema_migration_guard = SCHEMA_MIGRATION_LOCK
            .lock()
            .map_err(|error| db_error(format!("lock schema migrations: {error}")))?;
        let version = self.schema_version()?;
        let version_number = parse_and_check_schema_version(version.as_str())?;
        if version_number < 7 {
            let should_reclaim_space =
                super::schema_migrations::run_pre_v7_migrations(&self.conn, version.as_str())?;
            self.run_post_v7_migrations(version.as_str())?;
            super::schema_repairs::repair_current_schema_shape(self)?;
            if should_reclaim_space {
                reclaim_unused_pages(&self.conn)?;
            }
        } else {
            self.run_post_v7_migrations(version.as_str())?;
            super::schema_repairs::repair_current_schema_shape(self)?;
        }
        super::schema_repairs::repair_noncanonical_session_state_wire(self)?;
        Ok(())
    }

    fn run_post_v7_migrations(&self, version: &str) -> Result<(), CliError> {
        self.apply_pending_migrations(parse_and_check_schema_version(version)?)
    }

    fn apply_pending_migrations(&self, version_number: u8) -> Result<(), CliError> {
        self.apply_pending_migrations_v8_to_v24(version_number)?;
        self.apply_pending_migrations_v25_to_v45(version_number)?;
        self.apply_pending_migrations_v46(version_number)?;
        self.apply_pending_migrations_v47(version_number)
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "sequential migration chain has one if-guard per schema version step"
    )]
    fn apply_pending_migrations_v8_to_v24(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 7 {
            self.migrate_v7_to_v8()?;
        }
        if version_number <= 8 {
            self.migrate_v8_to_v9()?;
        }
        if version_number <= 9 {
            migrate_v9_to_v10(&self.conn)?;
        }
        if version_number <= 10 {
            migrate_v10_to_v11(&self.conn)?;
        }
        if version_number <= 11 {
            migrate_v11_to_v12(&self.conn)?;
        }
        if version_number <= 12 {
            migrate_v12_to_v13(&self.conn)?;
        }
        if version_number <= 13 {
            migrate_v13_to_v14(&self.conn)?;
        }
        if version_number <= 14 {
            migrate_v14_to_v15(&self.conn)?;
        }
        if version_number <= 15 {
            migrate_v15_to_v16(&self.conn)?;
        }
        if version_number <= 16 {
            migrate_v16_to_v17(&self.conn)?;
        }
        if version_number <= 17 {
            migrate_v17_to_v18(&self.conn)?;
        }
        if version_number <= 18 {
            migrate_v18_to_v19(&self.conn)?;
        }
        if version_number <= 19 {
            migrate_v19_to_v20(&self.conn)?;
        }
        if version_number <= 20 {
            migrate_v20_to_v21(&self.conn)?;
        }
        if version_number <= 21 {
            migrate_v21_to_v22(&self.conn)?;
        }
        if version_number <= 22 {
            migrate_v22_to_v23(&self.conn)?;
        }
        if version_number <= 23 {
            migrate_v23_to_v24(&self.conn)?;
        }
        Ok(())
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "sequential migration chain has one if-guard per schema version step"
    )]
    fn apply_pending_migrations_v25_to_v45(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 24 {
            migrate_v24_to_v25(&self.conn)?;
        }
        if version_number <= 25 {
            migrate_v25_to_v26(&self.conn)?;
        }
        if version_number <= 26 {
            migrate_v26_to_v27(&self.conn)?;
        }
        if version_number <= 27 {
            migrate_v27_to_v28(&self.conn)?;
        }
        if version_number <= 28 {
            migrate_v28_to_v29(&self.conn)?;
        }
        if version_number <= 29 {
            migrate_v29_to_v30(&self.conn)?;
        }
        if version_number <= 30 {
            migrate_v30_to_v31(&self.conn)?;
        }
        if version_number <= 31 {
            migrate_v31_to_v32(&self.conn)?;
        }
        if version_number <= 32 {
            migrate_v32_to_v33(&self.conn)?;
        }
        if version_number <= 33 {
            migrate_v33_to_v34(&self.conn)?;
        }
        if version_number <= 34 {
            migrate_v34_to_v35(&self.conn)?;
        }
        if version_number <= 35 {
            migrate_v35_to_v36(&self.conn)?;
        }
        if version_number <= 36 {
            migrate_v36_to_v37(&self.conn)?;
        }
        if version_number <= 37 {
            migrate_v37_to_v38(&self.conn)?;
        }
        if version_number <= 38 {
            migrate_v38_to_v39(&self.conn)?;
        }
        if version_number <= 39 {
            migrate_v39_to_v40(&self.conn)?;
        }
        if version_number <= 40 {
            migrate_v40_to_v41(&self.conn)?;
        }
        if version_number <= 41 {
            migrate_v41_to_v42(&self.conn)?;
        }
        if version_number <= 42 {
            migrate_v42_to_v43(&self.conn)?;
        }
        if version_number <= 43 {
            super::schema_v44::run(&self.conn)?;
        }
        if version_number <= 44 {
            super::schema_v45::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v46(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 45 {
            super::schema_v46::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v47(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 46 {
            super::schema_v47::run(&self.conn)?;
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
    test_support::run_schema_init_hook();
    conn.execute_batch(CREATE_SCHEMA)
        .map_err(|error| db_error(format!("create daemon database schema: {error}")))
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
