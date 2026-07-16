#[cfg(all(target_os = "linux", not(test)))]
use nix::unistd::syncfs;
#[cfg(all(target_os = "linux", not(test)))]
use std::fs::File;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use fs_err as fs;

use rusqlite::{Connection, OpenFlags};

use crate::errors::CliError;

use super::files::{
    io_error, regular_file_metadata, sqlite_error, sync_directory, sync_file, sync_parent,
};
use super::model::DatabaseSeal;

pub(super) fn checkpoint_database(path: &Path) -> Result<(bool, Option<i64>), CliError> {
    let seal = checkpoint_database_image(path)?;
    sync_database_image(path, seal)?;
    Ok((seal.present, seal.schema))
}

pub(super) fn seal_live_database_state(state_path: &Path) -> Result<DatabaseSeal, CliError> {
    let path = database_path(state_path);
    let seal = checkpoint_database_image(&path)?;
    sync_database_image(&path, seal)?;
    sync_state_filesystem(state_path)?;
    verify_database_image(&path, seal.present, seal.schema)?;
    Ok(seal)
}

pub(super) fn verify_live_database_seal(
    state_path: &Path,
    seal: DatabaseSeal,
) -> Result<(), CliError> {
    seal.validate()?;
    verify_database_image(&database_path(state_path), seal.present, seal.schema)
}

fn checkpoint_database_image(path: &Path) -> Result<DatabaseSeal, CliError> {
    validate_database_ancestors(path)?;
    if !path.exists() {
        return Ok(DatabaseSeal::new(false, None));
    }
    regular_file_metadata(path)?;
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| sqlite_error("open systemd database for snapshot", path, &error))?;
    assert_sqlite_integrity(&connection, path)?;
    let (busy, log_frames, checkpointed): (i64, i64, i64) = connection
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .map_err(|error| sqlite_error("checkpoint systemd database", path, &error))?;
    if busy != 0 || checkpointed < log_frames {
        return Err(io_error(format!(
            "SQLite checkpoint did not complete for {}: busy={busy}, log_frames={log_frames}, checkpointed={checkpointed}",
            path.display()
        )));
    }
    assert_sqlite_integrity(&connection, path)?;
    let schema = read_schema_version(&connection)?;
    drop(connection);
    Ok(DatabaseSeal::new(true, schema))
}

fn sync_database_image(path: &Path, seal: DatabaseSeal) -> Result<(), CliError> {
    if seal.present {
        sync_file(path)?;
        sync_parent(path)
    } else {
        sync_nearest_database_parent(path)
    }
}

fn sync_nearest_database_parent(path: &Path) -> Result<(), CliError> {
    let mut current = path
        .parent()
        .ok_or_else(|| io_error("systemd database path has no parent"))?;
    loop {
        match fs::symlink_metadata(current) {
            Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
                return sync_directory(current);
            }
            Ok(_) => {
                return Err(io_error(format!(
                    "systemd database parent is not a regular directory: {}",
                    current.display()
                )));
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {
                current = current
                    .parent()
                    .ok_or_else(|| io_error("systemd database has no existing parent directory"))?;
            }
            Err(error) => {
                return Err(io_error(format!(
                    "inspect systemd database parent {}: {error}",
                    current.display()
                )));
            }
        }
    }
}

fn sync_state_filesystem(state_path: &Path) -> Result<(), CliError> {
    let parent = state_path
        .parent()
        .ok_or_else(|| io_error("systemd state path has no parent"))?;
    #[cfg(all(target_os = "linux", not(test)))]
    {
        let directory = File::open(parent).map_err(|error| {
            io_error(format!(
                "open systemd state filesystem {}: {error}",
                parent.display()
            ))
        })?;
        syncfs(&directory).map_err(|error| {
            io_error(format!(
                "sync systemd state filesystem {}: {error}",
                parent.display()
            ))
        })
    }
    #[cfg(any(not(target_os = "linux"), test))]
    {
        sync_directory(parent)
    }
}

pub(super) fn verify_snapshot_database(
    state_snapshot: &Path,
    expected_present: bool,
    expected_schema: Option<i64>,
) -> Result<(), CliError> {
    let path = database_path(state_snapshot);
    verify_database_image(&path, expected_present, expected_schema)
}

pub(super) fn verify_restored_database(
    state_path: &Path,
    expected_present: bool,
    expected_schema: Option<i64>,
) -> Result<(), CliError> {
    let path = database_path(state_path);
    verify_database_image(&path, expected_present, expected_schema)
}

fn verify_database_image(
    path: &Path,
    expected_present: bool,
    expected_schema: Option<i64>,
) -> Result<(), CliError> {
    DatabaseSeal::new(expected_present, expected_schema).validate()?;
    validate_database_ancestors(path)?;
    if !expected_present {
        if path.exists() {
            return Err(io_error(format!(
                "restored generation unexpectedly contains database {}",
                path.display()
            )));
        }
        return Ok(());
    }
    regular_file_metadata(path)?;
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| sqlite_error("open database snapshot", path, &error))?;
    assert_sqlite_integrity(&connection, path)?;
    let actual_schema = read_schema_version(&connection)?;
    if actual_schema != expected_schema {
        return Err(io_error(format!(
            "database snapshot schema mismatch for {}: expected {expected_schema:?}, found {actual_schema:?}",
            path.display()
        )));
    }
    Ok(())
}

fn validate_database_ancestors(path: &Path) -> Result<(), CliError> {
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(io_error(format!(
                    "refusing symbolic link in systemd database path: {}",
                    current.display()
                )));
            }
            Ok(_) => {}
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(io_error(format!(
                    "inspect systemd database ancestor {}: {error}",
                    current.display()
                )));
            }
        }
    }
    Ok(())
}

fn assert_sqlite_integrity(connection: &Connection, path: &Path) -> Result<(), CliError> {
    let result: String = connection
        .query_row("PRAGMA quick_check", [], |row| row.get(0))
        .map_err(|error| sqlite_error("quick-check systemd database", path, &error))?;
    if result != "ok" {
        return Err(io_error(format!(
            "SQLite quick_check failed for {}: {result}",
            path.display()
        )));
    }
    assert_foreign_keys(connection, path)
}

fn assert_foreign_keys(connection: &Connection, path: &Path) -> Result<(), CliError> {
    let mut statement = connection
        .prepare("PRAGMA foreign_key_check")
        .map_err(|error| sqlite_error("prepare foreign-key check", path, &error))?;
    let mut rows = statement
        .query([])
        .map_err(|error| sqlite_error("run foreign-key check", path, &error))?;
    let Some(row) = rows
        .next()
        .map_err(|error| sqlite_error("read foreign-key check", path, &error))?
    else {
        return Ok(());
    };
    let table = row
        .get::<_, String>(0)
        .unwrap_or_else(|_| "<unknown>".to_string());
    let row_id = row.get::<_, Option<i64>>(1).unwrap_or(None);
    Err(io_error(format!(
        "SQLite foreign_key_check failed for {}: table={table}, rowid={row_id:?}",
        path.display()
    )))
}

fn read_schema_version(connection: &Connection) -> Result<Option<i64>, CliError> {
    match connection.query_row(
        "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'version'",
        [],
        |row| row.get(0),
    ) {
        Ok(version) => Ok(Some(version)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(rusqlite::Error::SqliteFailure(error, _)) if error.extended_code == 1 => Ok(None),
        Err(error) => Err(io_error(format!(
            "read systemd database schema version: {error}"
        ))),
    }
}

pub(super) fn database_path(state_path: &Path) -> PathBuf {
    state_path
        .join("daemon")
        .join("external")
        .join("harness.db")
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;
    use rusqlite::config::DbConfig;
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn schema_less_database_is_present_and_verifiable() {
        let temp = tempdir().expect("temp dir");
        let state = temp.path().join("state");
        let database = database_path(&state);
        fs::create_dir_all(database.parent().expect("database parent")).expect("database parent");
        Connection::open(&database)
            .expect("open legacy database")
            .execute_batch("CREATE TABLE legacy_canary (value TEXT NOT NULL);")
            .expect("create schema-less database");

        let (present, schema) = checkpoint_database(&database).expect("checkpoint legacy database");

        assert!(present);
        assert_eq!(schema, None);
        verify_restored_database(&state, present, schema).expect("verify legacy database");
    }

    #[test]
    fn absent_database_remains_distinct_from_schema_less_database() {
        let temp = tempdir().expect("temp dir");
        let state = temp.path().join("state");
        let database = database_path(&state);

        let (present, schema) = checkpoint_database(&database).expect("checkpoint absent database");

        assert!(!present);
        assert_eq!(schema, None);
        verify_restored_database(&state, present, schema).expect("verify absent database");
    }

    #[test]
    fn live_database_seal_distinguishes_absent_and_schema_less_images() {
        let temp = tempdir().expect("temp dir");
        let absent_state = temp.path().join("absent-state");
        let schema_less_state = temp.path().join("schema-less-state");
        let schema_less_database = database_path(&schema_less_state);
        fs::create_dir_all(schema_less_database.parent().expect("database parent"))
            .expect("database parent");
        Connection::open(&schema_less_database)
            .expect("open schema-less database")
            .execute_batch("CREATE TABLE legacy_canary (value TEXT NOT NULL);")
            .expect("create schema-less database");

        let absent = seal_live_database_state(&absent_state).expect("seal absent database");
        let schema_less =
            seal_live_database_state(&schema_less_state).expect("seal schema-less database");

        assert_eq!(absent, DatabaseSeal::new(false, None));
        assert_eq!(schema_less, DatabaseSeal::new(true, None));
        verify_live_database_seal(&absent_state, absent).expect("verify absent seal");
        verify_live_database_seal(&schema_less_state, schema_less)
            .expect("verify schema-less seal");
    }

    #[test]
    fn wal_backed_schema_change_is_checkpointed_and_reopened_by_live_seal() {
        let temp = tempdir().expect("temp dir");
        let state = temp.path().join("state");
        let database = database_path(&state);
        let wal = database_wal_path(&database);
        fs::create_dir_all(database.parent().expect("database parent")).expect("database parent");
        let connection = Connection::open(&database).expect("open WAL database");
        connection
            .set_db_config(DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, true)
            .expect("disable checkpoint on final close");
        connection
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 PRAGMA wal_autocheckpoint=0;
                 CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO schema_meta (key, value) VALUES ('version', '31');
                 UPDATE schema_meta SET value = '35' WHERE key = 'version';",
            )
            .expect("write WAL-backed schema change");
        drop(connection);
        assert!(
            fs::metadata(&wal).expect("uncheckpointed WAL").len() > 0,
            "test setup must leave schema changes in the WAL"
        );

        let seal = seal_live_database_state(&state).expect("seal WAL database");

        assert_eq!(seal, DatabaseSeal::new(true, Some(35)));
        verify_live_database_seal(&state, seal).expect("reopen sealed WAL database");
        let reopened = Connection::open_with_flags(&database, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("open sealed database read-only");
        assert_eq!(
            read_schema_version(&reopened).expect("sealed schema"),
            Some(35)
        );
        assert_eq!(wal_length_or_zero(&wal), 0, "sealing must drain the WAL");
    }

    fn database_wal_path(database: &Path) -> PathBuf {
        let mut path = database.as_os_str().to_owned();
        path.push("-wal");
        PathBuf::from(path)
    }

    fn wal_length_or_zero(path: &Path) -> u64 {
        match fs::metadata(path) {
            Ok(metadata) => metadata.len(),
            Err(error) if error.kind() == ErrorKind::NotFound => 0,
            Err(error) => panic!("inspect sealed WAL {}: {error}", path.display()),
        }
    }
}
