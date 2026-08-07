use super::audit_event_retention::prune_remote_audit_events;
use super::schema_sql::CREATE_SCHEMA;
use super::{CliError, Connection, DaemonDb, Path, SessionState, db_error};
use rusqlite::ffi::ErrorCode;
use rusqlite::{Transaction, TransactionBehavior};
use std::cell::RefCell;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

#[path = "schema_test_support.rs"]
mod test_support;

#[cfg(any(test, feature = "test-support"))]
pub use test_support::set_schema_init_hook;

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

/// Session/timeline repair callbacks the migration chain needs.
///
/// This file constructs [`DaemonDb`] and is the part of `db` slated to move
/// into its own crate, so it never calls a `harness-daemon` extension trait
/// (`SessionWriteQueries`/`DaemonDbTimeline`) by name - a caller supplies
/// the callbacks instead, keeping this file's only dependency on the rest
/// of the crate an explicit function argument.
pub struct SchemaRepairHooks {
    pub sync_session: fn(&DaemonDb, &str, &SessionState) -> Result<(), CliError>,
    pub backfill_legacy_timelines: fn(&DaemonDb) -> Result<(), CliError>,
}

impl DaemonDb {
    /// Open the daemon database at `path`, applying pragmas and running any
    /// pending schema migrations.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn open_with_hooks(path: &Path, hooks: &SchemaRepairHooks) -> Result<Self, CliError> {
        let conn = Connection::open(path)
            .map_err(|error| db_error(format!("open daemon database: {error}")))?;
        init::apply_pragmas(&conn)?;
        let db = Self {
            conn,
            path: Some(path.to_path_buf()),
            activity_fold: RefCell::new(super::activity_fold_cache::ActivityFoldCache::new()),
        };
        db.ensure_schema(hooks)?;
        prune_remote_audit_events(&db)?;
        Ok(db)
    }

    /// Open an in-memory database for testing.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    //
    // `test-support` alongside `test`: `harness-db-schema`'s own migration
    // tests build a real `DaemonDb` end-to-end rather than a hand-rolled
    // bootstrap, so its dev-dependency on this crate needs this reachable
    // outside `harness-daemon`'s own test build too.
    #[cfg(any(test, feature = "test-support"))]
    pub fn open_in_memory_with_hooks(hooks: &SchemaRepairHooks) -> Result<Self, CliError> {
        let conn = Connection::open_in_memory()
            .map_err(|error| db_error(format!("open in-memory database: {error}")))?;
        init::apply_pragmas(&conn)?;
        let db = Self {
            conn,
            path: None,
            activity_fold: RefCell::new(super::activity_fold_cache::ActivityFoldCache::new()),
        };
        db.ensure_schema(hooks)?;
        prune_remote_audit_events(&db)?;
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

    fn ensure_schema(&self, hooks: &SchemaRepairHooks) -> Result<(), CliError> {
        let transaction = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)
            .map_err(|error| db_error(format!("begin schema bootstrap transaction: {error}")))?;
        if !init::schema_exists(&transaction)? {
            init::create_schema(&transaction)?;
        }
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit schema bootstrap transaction: {error}")))?;
        self.run_migrations(hooks)
    }

    fn run_migrations(&self, hooks: &SchemaRepairHooks) -> Result<(), CliError> {
        let _schema_migration_guard = SCHEMA_MIGRATION_LOCK
            .lock()
            .map_err(|error| db_error(format!("lock schema migrations: {error}")))?;
        let version = self.schema_version()?;
        let version_number = init::parse_and_check_schema_version(version.as_str())?;
        if version_number < 7 {
            let should_reclaim_space =
                super::schema_migrations::run_pre_v7_migrations(&self.conn, version.as_str())?;
            self.run_post_v7_migrations(version.as_str(), hooks)?;
            harness_db_schema::schema_repairs::repair_current_schema_shape(
                &self.conn,
                super::SCHEMA_VERSION,
            )?;
            if should_reclaim_space {
                init::reclaim_unused_pages(&self.conn)?;
            }
        } else {
            self.run_post_v7_migrations(version.as_str(), hooks)?;
            harness_db_schema::schema_repairs::repair_current_schema_shape(
                &self.conn,
                super::SCHEMA_VERSION,
            )?;
        }
        harness_db_schema::schema_repairs::repair_noncanonical_session_state_wire(
            &self.conn,
            |project_id, state| (hooks.sync_session)(self, project_id, state),
        )?;
        Ok(())
    }

    fn run_post_v7_migrations(
        &self,
        version: &str,
        hooks: &SchemaRepairHooks,
    ) -> Result<(), CliError> {
        self.apply_pending_migrations(init::parse_and_check_schema_version(version)?, hooks)
    }

    fn apply_pending_migrations(
        &self,
        version_number: u8,
        hooks: &SchemaRepairHooks,
    ) -> Result<(), CliError> {
        self.apply_pending_migrations_v8_to_v24(version_number, hooks)?;
        self.apply_pending_migrations_v25_to_v45(version_number)?;
        self.apply_pending_migrations_v46(version_number)?;
        self.apply_pending_migrations_v47(version_number)?;
        self.apply_pending_migrations_v48(version_number)?;
        self.apply_pending_migrations_v49(version_number)?;
        self.apply_pending_migrations_v50(version_number)?;
        self.apply_pending_migrations_v51(version_number)?;
        self.apply_pending_migrations_v52(version_number)?;
        self.apply_pending_migrations_v53(version_number)?;
        self.apply_pending_migrations_v54(version_number)?;
        self.apply_pending_migrations_v55(version_number)?;
        self.apply_pending_migrations_v56(version_number)?;
        self.apply_pending_migrations_v57(version_number)?;
        self.apply_pending_migrations_v58(version_number)?;
        self.apply_pending_migrations_v59(version_number)?;
        self.apply_pending_migrations_v60(version_number)?;
        self.apply_pending_migrations_v61(version_number)?;
        self.apply_pending_migrations_v62(version_number)?;
        self.apply_pending_migrations_v63(version_number)?;
        self.apply_pending_migrations_v64(version_number)?;
        self.apply_pending_migrations_v65(version_number)?;
        self.apply_pending_migrations_v66(version_number)?;
        self.apply_pending_migrations_v67(version_number)
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "sequential migration chain has one if-guard per schema version step"
    )]
    fn apply_pending_migrations_v8_to_v24(
        &self,
        version_number: u8,
        hooks: &SchemaRepairHooks,
    ) -> Result<(), CliError> {
        if version_number <= 7 {
            self.migrate_v7_to_v8(hooks)?;
        }
        if version_number <= 8 {
            self.migrate_v8_to_v9(hooks)?;
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
            harness_db_schema::schema_v44::run(&self.conn)?;
        }
        if version_number <= 44 {
            harness_db_schema::schema_v45::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v46(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 45 {
            harness_db_schema::schema_v46::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v47(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 46 {
            harness_db_schema::schema_v47::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v48(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 47 {
            harness_db_schema::schema_v48::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v49(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 48 {
            harness_db_schema::schema_v49::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v50(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 49 {
            harness_db_schema::schema_v50::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v51(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 50 {
            harness_db_schema::schema_v51::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v52(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 51 {
            harness_db_schema::schema_v52::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v53(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 52 {
            harness_db_schema::schema_v53::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v54(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 53 {
            harness_db_schema::schema_v54::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v55(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 54 {
            harness_db_schema::schema_v55::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v56(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 55 {
            harness_db_schema::schema_v56::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v57(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 56 {
            harness_db_schema::schema_v57::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v58(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 57 {
            harness_db_schema::schema_v58::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v59(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 58 {
            harness_db_schema::schema_v59::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v60(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 59 {
            harness_db_schema::schema_v60::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v61(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 60 {
            harness_db_schema::schema_v61::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v62(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 61 {
            harness_db_schema::schema_v62::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v63(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 62 {
            harness_db_schema::schema_v63::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v64(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 63 {
            harness_db_schema::schema_v64::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v65(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 64 {
            harness_db_schema::schema_v65::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v66(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 65 {
            harness_db_schema::schema_v66::run(&self.conn)?;
        }
        Ok(())
    }

    fn apply_pending_migrations_v67(&self, version_number: u8) -> Result<(), CliError> {
        if version_number <= 66 {
            harness_db_schema::schema_v67::run(&self.conn)?;
        }
        Ok(())
    }

    fn migrate_v7_to_v8(&self, hooks: &SchemaRepairHooks) -> Result<(), CliError> {
        // v7 databases created before the backfill shipped have empty ledger
        // rows even when the legacy source tables still hold conversation
        // history. Rebuild every session's ledger, then stamp v8 so the
        // upgrade is one-shot and idempotent across restarts.
        (hooks.backfill_legacy_timelines)(self)?;
        self.conn
            .execute(
                "UPDATE schema_meta SET value = '8' WHERE key = 'version'",
                [],
            )
            .map_err(|error| db_error(format!("bump schema version to v8: {error}")))?;
        Ok(())
    }

    fn migrate_v8_to_v9(&self, hooks: &SchemaRepairHooks) -> Result<(), CliError> {
        harness_db_schema::schema_repairs::repair_stale_active_sessions_without_leader(
            &self.conn,
            |project_id, state| (hooks.sync_session)(self, project_id, state),
        )?;
        self.conn
            .execute(
                "UPDATE schema_meta SET value = '9' WHERE key = 'version'",
                [],
            )
            .map_err(|error| db_error(format!("bump schema version to v9: {error}")))?;
        Ok(())
    }
}

#[path = "schema_init.rs"]
mod init;
