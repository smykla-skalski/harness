use super::schema_sql::{AGENT_TUIS_SCHEMA, CODEX_RUNS_SCHEMA, CREATE_SCHEMA};
use super::{CliError, Connection, DaemonDb, Path, db_error};
use rusqlite::ffi::ErrorCode;
use rusqlite::{Transaction, TransactionBehavior};
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
        let db = Self { conn };
        db.ensure_schema()?;
        Ok(db)
    }

    /// Open an in-memory database for testing.
    #[cfg(test)]
    pub fn open_in_memory() -> Result<Self, CliError> {
        let conn = Connection::open_in_memory()
            .map_err(|error| db_error(format!("open in-memory database: {error}")))?;
        apply_pragmas(&conn)?;
        let db = Self { conn };
        db.ensure_schema()?;
        Ok(db)
    }

    /// Return the current schema version stored in `schema_meta`.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn schema_version(&self) -> Result<String, CliError> {
        self.conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .map_err(|error| db_error(format!("read schema version: {error}")))
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
        let needs_ledger_backfill =
            matches!(version.as_str(), "1" | "2" | "3" | "4" | "5" | "6" | "7");
        let should_reclaim_space = match version.as_str() {
            "1" => {
                self.conn
                    .execute_batch(
                        "ALTER TABLE sessions ADD COLUMN title TEXT NOT NULL DEFAULT '';
                         UPDATE sessions SET title = context;
                         UPDATE sessions SET state_json = json_set(state_json, '$.title', context);
                         UPDATE schema_meta SET value = '2' WHERE key = 'version';",
                    )
                    .map_err(|error| db_error(format!("migrate v1 -> v2: {error}")))?;
                let reclaimed = migrate_v2_to_v3(&self.conn)?;
                migrate_v3_to_v4(&self.conn)?;
                migrate_v4_to_v5(&self.conn)?;
                migrate_v5_to_v6(&self.conn)?;
                migrate_v6_to_v7(&self.conn)?;
                reclaimed
            }
            "2" => {
                let reclaimed = migrate_v2_to_v3(&self.conn)?;
                migrate_v3_to_v4(&self.conn)?;
                migrate_v4_to_v5(&self.conn)?;
                migrate_v5_to_v6(&self.conn)?;
                migrate_v6_to_v7(&self.conn)?;
                reclaimed
            }
            "3" => {
                migrate_v3_to_v4(&self.conn)?;
                migrate_v4_to_v5(&self.conn)?;
                migrate_v5_to_v6(&self.conn)?;
                migrate_v6_to_v7(&self.conn)?;
                false
            }
            "4" => {
                migrate_v4_to_v5(&self.conn)?;
                migrate_v5_to_v6(&self.conn)?;
                migrate_v6_to_v7(&self.conn)?;
                false
            }
            "5" => {
                migrate_v5_to_v6(&self.conn)?;
                migrate_v6_to_v7(&self.conn)?;
                false
            }
            "6" => {
                migrate_v6_to_v7(&self.conn)?;
                false
            }
            _ => false,
        };

        if needs_ledger_backfill {
            self.migrate_v7_to_v8()?;
        }

        if should_reclaim_space {
            reclaim_unused_pages(&self.conn)?;
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

fn table_exists(conn: &Connection, table_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table_name} table existence: {error}")))
}

fn column_exists(conn: &Connection, table_name: &str, column_name: &str) -> Result<bool, CliError> {
    let pragma = format!("PRAGMA table_info({table_name})");
    let columns = conn
        .prepare(&pragma)
        .and_then(|mut statement| {
            statement
                .query_map([], |row| row.get::<_, String>(1))
                .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        })
        .map_err(|error| db_error(format!("read {table_name} columns: {error}")))?;
    Ok(columns.iter().any(|column| column == column_name))
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

fn migrate_v2_to_v3(conn: &Connection) -> Result<bool, CliError> {
    let transaction = conn
        .unchecked_transaction()
        .map_err(|error| db_error(format!("begin v2 -> v3 migration: {error}")))?;

    let removed_conversation_duplicates = transaction
        .execute(
            "DELETE FROM conversation_events
             WHERE id NOT IN (
                 SELECT MIN(id)
                 FROM conversation_events
                 GROUP BY session_id, agent_id, sequence
             )",
            [],
        )
        .map_err(|error| db_error(format!("dedupe conversation events: {error}")))?;
    transaction
        .execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_conv_events_identity
             ON conversation_events(session_id, agent_id, sequence)",
            [],
        )
        .map_err(|error| db_error(format!("create conversation event identity index: {error}")))?;

    let removed_daemon_duplicates = transaction
        .execute(
            "DELETE FROM daemon_events
             WHERE id NOT IN (
                 SELECT MIN(id)
                 FROM daemon_events
                 GROUP BY recorded_at, level, message
             )",
            [],
        )
        .map_err(|error| db_error(format!("dedupe daemon events: {error}")))?;
    transaction
        .execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_daemon_events_identity
             ON daemon_events(recorded_at, level, message)",
            [],
        )
        .map_err(|error| db_error(format!("create daemon event identity index: {error}")))?;

    transaction
        .execute(
            "UPDATE schema_meta SET value = ?1 WHERE key = 'version'",
            ["3"],
        )
        .map_err(|error| db_error(format!("bump schema version to v3: {error}")))?;

    transaction
        .commit()
        .map_err(|error| db_error(format!("commit v2 -> v3 migration: {error}")))?;

    Ok(removed_conversation_duplicates > 0 || removed_daemon_duplicates > 0)
}

fn migrate_v3_to_v4(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(CODEX_RUNS_SCHEMA)
        .map_err(|error| db_error(format!("migrate v3 -> v4 codex runs: {error}")))?;
    conn.execute(
        "UPDATE schema_meta SET value = ?1 WHERE key = 'version'",
        ["4"],
    )
    .map_err(|error| db_error(format!("bump schema version to v4: {error}")))?;
    Ok(())
}

fn migrate_v4_to_v5(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(AGENT_TUIS_SCHEMA)
        .map_err(|error| db_error(format!("migrate v4 -> v5 agent tuis: {error}")))?;
    conn.execute(
        "UPDATE schema_meta SET value = ?1 WHERE key = 'version'",
        ["5"],
    )
    .map_err(|error| db_error(format!("bump schema version to v5: {error}")))?;
    Ok(())
}

fn migrate_v5_to_v6(conn: &Connection) -> Result<(), CliError> {
    if table_exists(conn, "change_tracking")? {
        if !column_exists(conn, "change_tracking", "change_seq")? {
            conn.execute_batch(
                "ALTER TABLE change_tracking
                     ADD COLUMN change_seq INTEGER NOT NULL DEFAULT 0;",
            )
            .map_err(|error| db_error(format!("add change_seq column: {error}")))?;
        }
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_change_tracking_change_seq
                 ON change_tracking(change_seq);
             UPDATE change_tracking
                SET change_seq = CASE
                    WHEN version > 0 THEN 1
                    ELSE 0
                END;",
        )
        .map_err(|error| db_error(format!("backfill change tracking sequence: {error}")))?;
    } else {
        conn.execute_batch(
            "CREATE TABLE change_tracking (
                 scope      TEXT PRIMARY KEY,
                 version    INTEGER NOT NULL DEFAULT 0,
                 updated_at TEXT NOT NULL,
                 change_seq INTEGER NOT NULL DEFAULT 0
             ) WITHOUT ROWID;
             CREATE INDEX idx_change_tracking_change_seq
                 ON change_tracking(change_seq);
             INSERT INTO change_tracking (scope, version, updated_at, change_seq)
             VALUES ('global', 0, datetime('now'), 0);",
        )
        .map_err(|error| db_error(format!("create v6 change tracking tables: {error}")))?;
    }

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS change_tracking_state (
             singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
             last_seq  INTEGER NOT NULL
         ) WITHOUT ROWID;
         INSERT INTO change_tracking_state (singleton, last_seq)
         VALUES (
             1,
             CASE
                 WHEN EXISTS(SELECT 1 FROM change_tracking WHERE version > 0) THEN 1
                 ELSE 0
             END
         )
         ON CONFLICT(singleton) DO UPDATE SET last_seq = excluded.last_seq;",
    )
    .map_err(|error| db_error(format!("seed change tracking sequence state: {error}")))?;
    conn.execute(
        "UPDATE schema_meta SET value = ?1 WHERE key = 'version'",
        ["6"],
    )
    .map_err(|error| db_error(format!("bump schema version to v6: {error}")))?;
    Ok(())
}

fn migrate_v6_to_v7(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS session_timeline_entries (
             session_id       TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
             entry_id         TEXT NOT NULL,
             source_kind      TEXT NOT NULL,
             source_key       TEXT NOT NULL,
             recorded_at      TEXT NOT NULL,
             kind             TEXT NOT NULL,
             agent_id         TEXT,
             task_id          TEXT,
             summary          TEXT NOT NULL,
             payload_json     TEXT NOT NULL,
             sort_recorded_at TEXT NOT NULL,
             sort_tiebreaker  TEXT NOT NULL,
             PRIMARY KEY (session_id, source_kind, source_key)
         ) WITHOUT ROWID;
         CREATE UNIQUE INDEX IF NOT EXISTS idx_session_timeline_entries_entry_id
             ON session_timeline_entries(session_id, entry_id);
         CREATE INDEX IF NOT EXISTS idx_session_timeline_entries_session_sort
             ON session_timeline_entries(session_id, sort_recorded_at DESC, sort_tiebreaker DESC);
         CREATE TABLE IF NOT EXISTS session_timeline_state (
             session_id          TEXT PRIMARY KEY REFERENCES sessions(session_id) ON DELETE CASCADE,
             revision            INTEGER NOT NULL DEFAULT 0,
             entry_count         INTEGER NOT NULL DEFAULT 0,
             newest_recorded_at  TEXT,
             oldest_recorded_at  TEXT,
             integrity_hash      TEXT NOT NULL DEFAULT '',
             updated_at          TEXT NOT NULL
         ) WITHOUT ROWID;
         INSERT OR IGNORE INTO session_timeline_state (
             session_id, revision, entry_count, newest_recorded_at,
             oldest_recorded_at, integrity_hash, updated_at
         )
         SELECT session_id, 0, 0, NULL, NULL, '', updated_at
         FROM sessions;",
    )
    .map_err(|error| db_error(format!("migrate v6 -> v7 timeline ledger: {error}")))?;
    conn.execute(
        "UPDATE schema_meta SET value = '7' WHERE key = 'version'",
        [],
    )
    .map_err(|error| db_error(format!("bump schema version to v7: {error}")))?;
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrate_v5_to_v6_stamps_intermediate_version() {
        let conn = Connection::open_in_memory().expect("open sqlite");
        conn.execute_batch(
            "CREATE TABLE schema_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO schema_meta (key, value) VALUES ('version', '5');
                CREATE TABLE change_tracking (
                    scope TEXT PRIMARY KEY,
                    version INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                ) WITHOUT ROWID;",
        )
        .expect("seed v5 schema");

        migrate_v5_to_v6(&conn).expect("migrate v5 to v6");

        let version: String = conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'version'",
                [],
                |row| row.get(0),
            )
            .expect("read schema version");
        assert_eq!(version, "6");
    }
}
