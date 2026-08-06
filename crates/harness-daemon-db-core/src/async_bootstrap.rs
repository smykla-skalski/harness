use sqlx::migrate::{Migration, Migrator};
use sqlx::{SqlitePool, query, query_as, query_scalar};

use super::{CliError, Connection, DaemonDb, Path, SchemaRepairHooks, db_error};

const TABLE_EXISTS_SQL: &str =
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?1";
const COLUMN_EXISTS_SQL: &str = "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2";
const SCHEMA_VERSION_SQL: &str = "SELECT value FROM schema_meta WHERE key = 'version'";
const SQLX_MIGRATIONS_TABLE_SQL: &str = "
CREATE TABLE IF NOT EXISTS _sqlx_migrations (
    version BIGINT PRIMARY KEY,
    description TEXT NOT NULL,
    installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    success BOOLEAN NOT NULL,
    checksum BLOB NOT NULL,
    execution_time BIGINT NOT NULL
)";
const SQLX_MIGRATION_METADATA_SQL: &str =
    "SELECT description, checksum FROM _sqlx_migrations WHERE version = ?1";
const INSERT_SQLX_MIGRATION_SQL: &str = "
INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time)
VALUES (?1, ?2, TRUE, ?3, 0)";
const UPDATE_SQLX_MIGRATION_METADATA_SQL: &str =
    "UPDATE _sqlx_migrations SET description = ?2, checksum = ?3 WHERE version = ?1";
const AGENT_TURN_RUNS_MIGRATION_VERSION: i64 = 58;
const MODIFIED_AGENT_TURN_RUNS_CHECKSUM: &str = "BB276C3EA875F30B7FE1BE84A078D14AE950E38D3B9F4489E6D8CACEF966056AFA96F74153221DF6070A8B38B561B82F";
// `sqlx::migrate!` resolves relative to this crate's own `CARGO_MANIFEST_DIR`;
// unlike `harness-daemon`, nothing path-includes this crate's source into a
// facade with a different manifest directory, so a single path suffices.
static DAEMON_DB_MIGRATOR: Migrator = sqlx::migrate!("src/migrations");

pub(super) async fn ensure_async_schema(pool: &SqlitePool) -> Result<(), CliError> {
    if !table_exists(pool, "schema_meta").await? {
        run_daemon_migrator(pool).await?;
        return Ok(());
    }
    ensure_baseline_migration_recorded(pool).await?;
    let version = read_async_schema_version(pool).await?;
    ensure_schema_meta_migrations_recorded(pool, &version).await?;
    repair_modified_agent_turn_runs_checksum(pool).await?;
    run_daemon_migrator(pool).await
}

/// Every migration the binary carries. Tests that assert a fully migrated
/// database read this instead of a literal range, so adding a migration does
/// not mean rewriting a number in unrelated tests.
#[cfg(any(test, feature = "test-support"))]
#[must_use]
pub fn all_migration_versions() -> Vec<i64> {
    DAEMON_DB_MIGRATOR
        .iter()
        .map(|migration| migration.version)
        .collect()
}

async fn ensure_schema_meta_migrations_recorded(
    pool: &SqlitePool,
    version: &str,
) -> Result<(), CliError> {
    let reached: u64 = version.parse().unwrap_or(0);
    for migration in DAEMON_DB_MIGRATOR.iter() {
        if migration.version == 1 {
            continue;
        }
        let migration_floor = migration_floor_version(migration.version);
        if reached < migration_floor && !migration_effect_observed(pool, migration.version).await? {
            continue;
        }
        record_migration_if_missing(pool, migration).await?;
    }
    Ok(())
}

async fn migration_effect_observed(
    pool: &SqlitePool,
    migration_version: i64,
) -> Result<bool, CliError> {
    if migration_version == 17 {
        return policy_snapshot_migration_effect_observed(pool).await;
    }
    if migration_version == 18 {
        return table_exists(pool, "audit_events").await;
    }
    if migration_version == 63 {
        return table_exists(pool, "task_board_ai_review_report_order").await;
    }
    if migration_version == 64 {
        return table_exists(pool, "agent_workspaces").await;
    }
    if migration_version == 65 {
        return table_exists(pool, "agent_workspace_teams").await;
    }
    if migration_version == 66 {
        return table_exists(pool, "agent_working_copies").await;
    }
    if migration_version == 70 {
        return column_exists(pool, "task_board_dispatch_intents", "workspace_id").await;
    }
    if migration_version == 71 {
        return table_exists(pool, "agent_workspace_activity_state").await;
    }
    let Some((table, column)) = migration_effect_column(migration_version) else {
        return Ok(false);
    };
    column_exists(pool, table, column).await
}

async fn policy_snapshot_migration_effect_observed(pool: &SqlitePool) -> Result<bool, CliError> {
    let has_global_flag = column_exists(
        pool,
        "policy_workspace",
        "global_policy_enforcement_enabled",
    )
    .await?;
    let has_snapshot = column_exists(pool, "policy_workspace", "enforcement_snapshot_json").await?;
    Ok(has_global_flag && !has_snapshot)
}

const fn migration_effect_column(migration_version: i64) -> Option<(&'static str, &'static str)> {
    match migration_version {
        16 => Some(("policy_workspace", "global_policy_enforcement_enabled")),
        19 => Some(("policy_workspace", "scenarios_json")),
        20 => Some(("policy_canvases", "live_document_json")),
        21 => Some(("remote_clients", "client_id")),
        22 => Some(("remote_acme_state", "domain")),
        23 => Some(("remote_acme_state", "account_credentials_json")),
        24 => Some(("task_board_items", "revision")),
        29 => Some(("task_board_dispatch_intents", "consumed_approval_grant_id")),
        30 => Some(("task_board_items", "workflow_kind")),
        35 => Some(("task_board_execution_hosts", "observed_host_instance_id")),
        40 => Some(("task_board_items", "tombstone_cause")),
        41 => Some(("task_board_items", "triage_override_verdict")),
        46 => Some(("task_board_items", "source_project_id")),
        48 => Some(("task_board_projects", "color")),
        50 => Some(("task_board_projects", "shape")),
        60 => Some(("task_board_ai_review_reports", "requested_runtime")),
        61 => Some(("task_board_ai_review_reports", "actual_runtime")),
        67 => Some(("agent_tuis", "workspace_id")),
        68 => Some(("codex_runs", "workspace_id")),
        69 => Some(("task_board_items", "workspace_id")),
        _ => None,
    }
}

/// The `schema_meta.version` threshold for each sqlx migration id. Used to
/// decide whether the sync path already applied an async migration so we can
/// seed its ledger row instead of re-running the statements.
const fn migration_floor_version(migration_version: i64) -> u64 {
    match migration_version {
        2 => 8,
        3 => 9,
        4 => 10,
        5 => 11,
        6 => 12,
        7 => 13,
        8 => 14,
        9 => 15,
        10 => 16,
        11 => 17,
        12 => 18,
        13 => 19,
        14 => 20,
        15 => 21,
        16 => 22,
        17 => 23,
        18 => 24,
        19 => 25,
        20 => 26,
        21 => 27,
        22 => 28,
        23 => 29,
        24 => 30,
        25 => 31,
        26 => 32,
        27 => 33,
        28 => 34,
        29 => 35,
        30 => 36,
        31 => 37,
        32 => 38,
        33 => 39,
        34 => 40,
        35 => 41,
        36 => 42,
        37 => 43,
        38 => 44,
        39 => 45,
        40 => 46,
        41 => 47,
        42 => 48,
        43 => 49,
        44 => 50,
        // Schema v51 ships as three files: the projects table, the item
        // attribution that references it, and the index kept separate so it
        // can be rebuilt on its own.
        45..=47 => 51,
        // Schema v52 splits the same way: the one-shot ALTER, then the
        // replayable backfill that carries the stamp.
        48..=49 => 52,
        // v53 adds the second half of the mark the same way round.
        50..=51 => 53,
        // Schema v54 ships as two files: the Todoist row cleanup and the
        // task_board_projects rebuild that drops 'todoist' from its source
        // check.
        52..=53 => 54,
        // v55 is one replayable statement pair: the scope backfill for roles
        // that gained `pair_manage`.
        54 => 55,
        // v56 renames the task-board inbox lane. The synchronous path also
        // canonicalizes nested JSON status fields before it seeds this row.
        55 => 56,
        // v57 adds the durable pull_request_actions ledger.
        56 => 57,
        // v58 adds append-only AI review reports.
        57 => 58,
        // v59 adds the durable agent_turn_runs table for provider-backed report runs.
        58 => 59,
        // v60 retains the provider-owned turn identity for report harvesting.
        59 => 60,
        // v61 splits report runtime provenance across replayable ALTERs.
        60..=62 => 61,
        // v62 adds the append-order ledger for retained AI review reports.
        63 => 62,
        // v63 adds durable agent workspaces and their reconciliation journal.
        64 => 63,
        // v64 adds workspace-owned agent teams and runtime operation results.
        65 => 64,
        // v65 ships as five files: the working-copy registry, then one owner
        // column per table it reaches, so the repair chain can skip whichever
        // parts a database already has.
        66..=70 => 65,
        // v66 adds workspace-owned signals, transcripts, activity, and timeline history.
        71 => 66,
        _ => u64::MAX,
    }
}

async fn record_migration_if_missing(
    pool: &SqlitePool,
    migration: &'static Migration,
) -> Result<(), CliError> {
    let checksum = migration.checksum.as_ref().to_vec();
    let applied = query_as::<_, (String, Vec<u8>)>(SQLX_MIGRATION_METADATA_SQL)
        .bind(migration.version)
        .fetch_optional(pool)
        .await
        .map_err(|error| db_error(format!("load async migration metadata: {error}")))?;
    if applied.is_some() {
        return Ok(());
    }
    query(INSERT_SQLX_MIGRATION_SQL)
        .bind(migration.version)
        .bind(migration.description.to_string())
        .bind(checksum)
        .execute(pool)
        .await
        .map_err(|error| db_error(format!("seed async migration ledger: {error}")))?;
    Ok(())
}

async fn repair_modified_agent_turn_runs_checksum(pool: &SqlitePool) -> Result<(), CliError> {
    let migration = DAEMON_DB_MIGRATOR
        .iter()
        .find(|migration| migration.version == AGENT_TURN_RUNS_MIGRATION_VERSION)
        .ok_or_else(|| db_error("missing agent turn runs migration"))?;
    let applied = query_as::<_, (String, Vec<u8>)>(SQLX_MIGRATION_METADATA_SQL)
        .bind(migration.version)
        .fetch_optional(pool)
        .await
        .map_err(|error| db_error(format!("load agent turn runs migration metadata: {error}")))?;
    let Some((description, checksum)) = applied else {
        return Ok(());
    };
    let modified_checksum = hex::decode(MODIFIED_AGENT_TURN_RUNS_CHECKSUM).map_err(|error| {
        db_error(format!(
            "decode agent turn runs migration checksum: {error}"
        ))
    })?;
    if description != migration.description || checksum != modified_checksum {
        return Ok(());
    }

    query(UPDATE_SQLX_MIGRATION_METADATA_SQL)
        .bind(migration.version)
        .bind(migration.description.to_string())
        .bind(migration.checksum.as_ref().to_vec())
        .execute(pool)
        .await
        .map_err(|error| db_error(format!("repair agent turn runs migration ledger: {error}")))?;
    Ok(())
}

pub(super) async fn read_async_schema_version(pool: &SqlitePool) -> Result<String, CliError> {
    query_scalar::<_, String>(SCHEMA_VERSION_SQL)
        .fetch_one(pool)
        .await
        .map_err(|error| db_error(format!("read async schema version: {error}")))
}

pub(super) fn prepare_legacy_schema(
    path: &Path,
    hooks: &SchemaRepairHooks,
) -> Result<(), CliError> {
    if !path.exists() {
        return Ok(());
    }

    let conn = Connection::open(path)
        .map_err(|error| db_error(format!("inspect async daemon database: {error}")))?;
    if !sync_table_exists(&conn, "schema_meta")? {
        return Ok(());
    }

    let version: String = conn
        .query_row(SCHEMA_VERSION_SQL, [], |row| row.get(0))
        .map_err(|error| db_error(format!("inspect async schema version: {error}")))?;
    let needs_shape_repair =
        harness_db_schema::schema_repairs::current_schema_shape_needs_repair(&conn)?;
    drop(conn);

    if version != super::SCHEMA_VERSION || needs_shape_repair {
        let _ = DaemonDb::open_with_hooks(path, hooks)?;
    }
    Ok(())
}

async fn ensure_baseline_migration_recorded(pool: &SqlitePool) -> Result<(), CliError> {
    if !table_exists(pool, "_sqlx_migrations").await? {
        query(SQLX_MIGRATIONS_TABLE_SQL)
            .execute(pool)
            .await
            .map_err(|error| db_error(format!("create async migration ledger: {error}")))?;
    }

    let baseline = baseline_migration()?;
    let applied = query_as::<_, (String, Vec<u8>)>(SQLX_MIGRATION_METADATA_SQL)
        .bind(baseline.version)
        .fetch_optional(pool)
        .await
        .map_err(|error| db_error(format!("load async migration metadata: {error}")))?;
    let baseline_checksum = baseline.checksum.as_ref().to_vec();
    if let Some((description, checksum)) = applied {
        // Existing daemon databases seed the SQLx baseline row as a
        // compatibility shim. Keep that shim aligned with the shipped baseline
        // snapshot so later forward migrations can validate and apply cleanly.
        if description == baseline.description && checksum == baseline_checksum {
            return Ok(());
        }
        query(UPDATE_SQLX_MIGRATION_METADATA_SQL)
            .bind(baseline.version)
            .bind(baseline.description.to_string())
            .bind(baseline_checksum)
            .execute(pool)
            .await
            .map_err(|error| {
                db_error(format!("repair async baseline migration ledger: {error}"))
            })?;
        return Ok(());
    }

    query(INSERT_SQLX_MIGRATION_SQL)
        .bind(baseline.version)
        .bind(baseline.description.to_string())
        .bind(baseline_checksum)
        .execute(pool)
        .await
        .map_err(|error| db_error(format!("seed async migration ledger: {error}")))?;
    Ok(())
}

async fn table_exists(pool: &SqlitePool, table_name: &str) -> Result<bool, CliError> {
    query_scalar::<_, i64>(TABLE_EXISTS_SQL)
        .bind(table_name)
        .fetch_one(pool)
        .await
        .map(|count| count > 0)
        .map_err(|error| db_error(format!("check async table {table_name} existence: {error}")))
}

async fn column_exists(
    pool: &SqlitePool,
    table_name: &str,
    column_name: &str,
) -> Result<bool, CliError> {
    query_scalar::<_, i64>(COLUMN_EXISTS_SQL)
        .bind(table_name)
        .bind(column_name)
        .fetch_one(pool)
        .await
        .map(|count| count > 0)
        .map_err(|error| {
            db_error(format!(
                "check async column {table_name}.{column_name}: {error}"
            ))
        })
}

fn sync_table_exists(conn: &Connection, table_name: &str) -> Result<bool, CliError> {
    conn.query_row(TABLE_EXISTS_SQL, [table_name], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .map_err(|error| db_error(format!("check sync table {table_name} existence: {error}")))
}

fn baseline_migration() -> Result<&'static Migration, CliError> {
    DAEMON_DB_MIGRATOR
        .iter()
        .next()
        .ok_or_else(|| db_error("missing daemon async baseline migration"))
}

/// Migrations that rebuild a referenced table have to rename it, and `SQLite`
/// rewrites every REFERENCES clause pointing at a renamed table while
/// enforcement is on - which turns the rename into a dangling foreign key once
/// the temp table is dropped. The pragma is ignored inside a transaction and
/// sqlx wraps each migration in one, so enforcement is suspended around the
/// whole run on a single connection instead.
async fn run_daemon_migrator(pool: &SqlitePool) -> Result<(), CliError> {
    let mut conn = pool
        .acquire()
        .await
        .map_err(|error| db_error(format!("acquire async migration connection: {error}")))?;
    query("PRAGMA foreign_keys = OFF")
        .execute(&mut *conn)
        .await
        .map_err(|error| {
            db_error(format!(
                "suspend foreign keys for async migrations: {error}"
            ))
        })?;
    query("PRAGMA legacy_alter_table = ON")
        .execute(&mut *conn)
        .await
        .map_err(|error| db_error(format!("suspend alter-table fixups: {error}")))?;
    let migrated = DAEMON_DB_MIGRATOR
        .run_direct(None, &mut *conn, false)
        .await
        .map_err(|error| db_error(format!("run async daemon migrations: {error}")));
    let restored = restore_migration_pragmas(&mut conn).await;
    migrated.and(restored)
}

/// The connection goes back to the pool afterwards, so a restore that misses a
/// statement leaves that one connection with enforcement off while every other
/// connection in the pool has it on. Each pragma is its own statement because
/// `SQLite` prepares one statement at a time.
async fn restore_migration_pragmas(conn: &mut sqlx::SqliteConnection) -> Result<(), CliError> {
    for pragma in [
        "PRAGMA legacy_alter_table = OFF",
        "PRAGMA foreign_keys = ON",
    ] {
        query(pragma).execute(&mut *conn).await.map_err(|error| {
            db_error(format!("restore pragmas after async migrations: {error}"))
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod pragma_tests {
    use super::{SchemaRepairHooks, query, restore_migration_pragmas};
    use crate::AsyncDaemonDb;

    /// The hooks are unreachable here: `connect_with_hooks` only threads them
    /// through `prepare_legacy_schema`, which is a no-op for a path that does
    /// not exist yet (see its own early return), and this test always opens a
    /// fresh `tempdir` path.
    fn unreachable_repair_hooks() -> SchemaRepairHooks {
        SchemaRepairHooks {
            sync_session: |_, _, _| unreachable!("fresh db never re-runs legacy repairs"),
            backfill_legacy_timelines: |_| unreachable!("fresh db never re-runs legacy repairs"),
        }
    }

    /// Reading the pragma back through the pool proves nothing: the pool opens
    /// connections with `foreign_keys(true)`, so it can answer from a connection
    /// that was never suspended. This asserts on the same connection the restore
    /// ran against, which is the one handed back to the pool.
    #[tokio::test]
    async fn restoring_pragmas_applies_every_statement_on_that_connection() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect_with_hooks(
            &dir.path().join("harness.db"),
            &unreachable_repair_hooks(),
        )
        .await
        .expect("open async db");
        let mut conn = db.pool().acquire().await.expect("acquire connection");
        for pragma in [
            "PRAGMA foreign_keys = OFF",
            "PRAGMA legacy_alter_table = ON",
        ] {
            query(pragma)
                .execute(&mut *conn)
                .await
                .expect("suspend pragma");
        }

        restore_migration_pragmas(&mut conn)
            .await
            .expect("restore pragmas");

        let foreign_keys: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
            .fetch_one(&mut *conn)
            .await
            .expect("foreign_keys pragma");
        let legacy_alter_table: i64 = sqlx::query_scalar("PRAGMA legacy_alter_table")
            .fetch_one(&mut *conn)
            .await
            .expect("legacy_alter_table pragma");

        assert_eq!(
            (foreign_keys, legacy_alter_table),
            (1, 0),
            "a statement in the restore never reached the migrator's connection"
        );
    }
}
