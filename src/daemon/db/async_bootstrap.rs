use sqlx::migrate::{Migration, Migrator};
use sqlx::{SqlitePool, query, query_as, query_scalar};

use super::{CliError, Connection, DaemonDb, Path, db_error};

const TABLE_EXISTS_SQL: &str =
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?1";
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
static DAEMON_DB_MIGRATOR: Migrator = sqlx::migrate!("./src/daemon/db/migrations");

pub(super) async fn ensure_async_schema(pool: &SqlitePool) -> Result<(), CliError> {
    if !table_exists(pool, "schema_meta").await? {
        run_daemon_migrator(pool).await?;
        return Ok(());
    }
    ensure_baseline_migration_recorded(pool).await?;
    let version = read_async_schema_version(pool).await?;
    ensure_schema_meta_migrations_recorded(pool, &version).await?;
    run_daemon_migrator(pool).await
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
        if reached < migration_floor {
            continue;
        }
        record_migration_if_missing(pool, migration).await?;
    }
    Ok(())
}

/// The `schema_meta.version` threshold for each sqlx migration id. Used to
/// decide whether the sync path already applied an async migration so we can
/// seed its ledger row instead of re-running the statements.
const fn migration_floor_version(migration_version: i64) -> u64 {
    match migration_version {
        2 => 8,
        3 => 9,
        4 => 10,
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

pub(super) async fn read_async_schema_version(pool: &SqlitePool) -> Result<String, CliError> {
    query_scalar::<_, String>(SCHEMA_VERSION_SQL)
        .fetch_one(pool)
        .await
        .map_err(|error| db_error(format!("read async schema version: {error}")))
}

pub(super) fn prepare_legacy_schema(path: &Path) -> Result<(), CliError> {
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
    drop(conn);

    if version != super::SCHEMA_VERSION {
        let _ = DaemonDb::open(path)?;
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

async fn run_daemon_migrator(pool: &SqlitePool) -> Result<(), CliError> {
    DAEMON_DB_MIGRATOR
        .run(pool)
        .await
        .map_err(|error| db_error(format!("run async daemon migrations: {error}")))
}
