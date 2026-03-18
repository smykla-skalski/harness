use std::fs::{self, OpenOptions};
use std::marker::PhantomData;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use fs2::FileExt;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind, cow};
use crate::io;

/// Error for invalid state transitions.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct TransitionError(pub String);

type MigrationFn = Arc<dyn Fn(Value) -> Result<Value, CliError> + Send + Sync>;

/// Versioned JSON repository with atomic save, migrations, and lock-backed updates.
pub struct VersionedJsonRepository<T> {
    path: PathBuf,
    current_version: u32,
    migrations: Vec<MigrationFn>,
    marker: PhantomData<fn() -> T>,
}

impl<T> VersionedJsonRepository<T>
where
    T: Serialize + DeserializeOwned,
{
    #[must_use]
    pub fn new(path: PathBuf, current_version: u32) -> Self {
        Self {
            path,
            current_version,
            migrations: Vec::new(),
            marker: PhantomData,
        }
    }

    #[must_use]
    pub fn with_migrations(
        mut self,
        migrations: Vec<Box<dyn Fn(Value) -> Result<Value, CliError> + Send + Sync>>,
    ) -> Self {
        self.migrations = migrations.into_iter().map(Arc::from).collect();
        self
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    #[must_use]
    pub fn current_version(&self) -> u32 {
        self.current_version
    }

    /// Load state from the JSON file.
    ///
    /// # Errors
    /// Returns `CliError` on IO, migration, or parse failure.
    pub fn load(&self) -> Result<Option<T>, CliError> {
        let Some(contents) = self.read_value()? else {
            return Ok(None);
        };
        if self.schema_version(&contents) == self.current_version {
            return self.deserialize(contents).map(Some);
        }

        self.with_exclusive_lock(|| {
            let Some((migrated, changed)) = self.read_migrated_value()? else {
                return Ok(None);
            };
            if changed {
                self.write_value(&migrated)?;
            }
            self.deserialize(migrated).map(Some)
        })
    }

    /// Save state to the JSON file atomically.
    ///
    /// # Errors
    /// Returns `CliError` on IO or serialization failure.
    pub fn save(&self, state: &T) -> Result<(), CliError> {
        let value = self.serialize(state)?;
        self.with_exclusive_lock(|| self.write_value(&value))
    }

    /// Load, modify, and save state while holding an exclusive lock.
    ///
    /// # Errors
    /// Returns `CliError` on IO, migration, parse, or closure failure.
    pub fn update<F>(&self, update: F) -> Result<Option<T>, CliError>
    where
        F: FnOnce(Option<T>) -> Result<Option<T>, CliError>,
    {
        self.with_exclusive_lock(|| {
            let (current_value, migrated) = match self.read_migrated_value()? {
                Some((value, changed)) => (Some(value), changed),
                None => (None, false),
            };
            let current = current_value
                .clone()
                .map(|value| self.deserialize(value))
                .transpose()?;
            let next = update(current)?;

            if let Some(state) = next.as_ref() {
                let value = self.serialize(state)?;
                self.write_value(&value)?;
            } else if migrated && let Some(value) = current_value.as_ref() {
                self.write_value(value)?;
            }

            Ok(next)
        })
    }

    fn read_value(&self) -> Result<Option<Value>, CliError> {
        if !self.path.exists() {
            return Ok(None);
        }
        io::read_json_typed(&self.path)
            .map(Some)
            .map_err(|error| self.workflow_parse_error(error))
    }

    fn read_migrated_value(&self) -> Result<Option<(Value, bool)>, CliError> {
        let Some(contents) = self.read_value()? else {
            return Ok(None);
        };
        let (migrated, changed) = self.migrate_value(contents)?;
        Ok(Some((migrated, changed)))
    }

    fn migrate_value(&self, contents: Value) -> Result<(Value, bool), CliError> {
        let mut version = self.schema_version(&contents);
        if version == self.current_version {
            return Ok((contents, false));
        }
        if version == 0 {
            return Err(CliErrorKind::workflow_version(cow!(
                "{} is missing schema_version",
                self.path.display()
            ))
            .into());
        }
        if version > self.current_version {
            return Err(CliErrorKind::workflow_version(cow!(
                "v{version} is newer than supported v{}",
                self.current_version
            ))
            .into());
        }

        let mut data = contents;
        while version < self.current_version {
            let migration_index = usize::try_from(version - 1).map_err(|error| {
                CliErrorKind::workflow_version(cow!(
                    "invalid migration index for v{version}: {error}"
                ))
            })?;
            let migration = self.migrations.get(migration_index).ok_or_else(|| {
                CliErrorKind::workflow_version(cow!(
                    "no migration from v{version} to v{} for {}",
                    version + 1,
                    self.path.display()
                ))
            })?;
            data = migration(data)?;

            let next_version = self.schema_version(&data);
            if next_version != version + 1 {
                return Err(CliErrorKind::workflow_version(cow!(
                    "migration for {} produced schema version v{next_version}, expected v{}",
                    self.path.display(),
                    version + 1
                ))
                .into());
            }
            version = next_version;
        }

        Ok((data, true))
    }

    fn serialize(&self, state: &T) -> Result<Value, CliError> {
        serde_json::to_value(state).map_err(|error| -> CliError {
            CliErrorKind::workflow_serialize(cow!(
                "failed to serialize {}: {error}",
                self.path.display()
            ))
            .into()
        })
    }

    fn deserialize(&self, contents: Value) -> Result<T, CliError> {
        serde_json::from_value(contents).map_err(|error| self.workflow_parse_error(error))
    }

    fn write_value(&self, value: &Value) -> Result<(), CliError> {
        io::write_json_pretty(&self.path, value).map_err(|error| -> CliError {
            CliErrorKind::workflow_io(cow!("failed to write {}: {error}", self.path.display()))
                .into()
        })
    }

    fn schema_version(&self, contents: &Value) -> u32 {
        contents
            .get("schema_version")
            .and_then(Value::as_u64)
            .and_then(|version| u32::try_from(version).ok())
            .unwrap_or(0)
    }

    fn workflow_parse_error(&self, error: impl std::fmt::Display) -> CliError {
        CliErrorKind::workflow_parse(cow!("failed to parse {}: {error}", self.path.display()))
            .with_details(error.to_string())
    }

    fn lock_path(&self) -> PathBuf {
        let file_name = self
            .path
            .file_name()
            .and_then(std::ffi::OsStr::to_str)
            .map_or_else(|| "state.json".to_string(), ToString::to_string);
        self.path.with_file_name(format!("{file_name}.lock"))
    }

    fn open_lock_file(&self) -> Result<std::fs::File, CliError> {
        let lock_path = self.lock_path();
        if let Some(parent) = lock_path.parent() {
            fs::create_dir_all(parent).map_err(|error| -> CliError {
                CliErrorKind::workflow_io(cow!(
                    "failed to create lock directory {}: {error}",
                    parent.display()
                ))
                .into()
            })?;
        }

        OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|error| -> CliError {
                CliErrorKind::workflow_io(cow!(
                    "failed to open workflow lock {}: {error}",
                    lock_path.display()
                ))
                .into()
            })
    }

    fn with_exclusive_lock<R>(
        &self,
        action: impl FnOnce() -> Result<R, CliError>,
    ) -> Result<R, CliError> {
        let lock_file = self.open_lock_file()?;
        lock_file.lock_exclusive().map_err(|error| -> CliError {
            CliErrorKind::workflow_io(cow!(
                "failed to acquire workflow lock {}: {error}",
                self.lock_path().display()
            ))
            .into()
        })?;

        let result = action();
        let unlock_result = lock_file.unlock().map_err(|error| -> CliError {
            CliErrorKind::workflow_io(cow!(
                "failed to release workflow lock {}: {error}",
                self.lock_path().display()
            ))
            .into()
        });

        match (result, unlock_result) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(error), Ok(())) | (Err(error), Err(_)) => Err(error),
            (Ok(_), Err(error)) => Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;

    use super::*;
    use serde_json::json;
    use tempfile::TempDir;

    #[test]
    fn load_returns_none_when_file_missing() {
        let dir = TempDir::new().unwrap();
        let repo = VersionedJsonRepository::<Value>::new(dir.path().join("state.json"), 1);
        assert!(repo.load().unwrap().is_none());
    }

    #[test]
    fn save_and_load_round_trip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path, 1);
        let state = json!({"schema_version": 1, "phase": "bootstrap"});
        repo.save(&state).unwrap();
        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["phase"], "bootstrap");
    }

    #[test]
    fn load_rejects_wrong_version() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path.clone(), 2);
        let state = json!({"schema_version": 99, "phase": "bootstrap"});
        fs::write(&path, serde_json::to_string(&state).unwrap()).unwrap();
        let err = repo.load().unwrap_err();
        assert!(err.message().contains("unsupported"));
    }

    #[test]
    fn load_migrates_older_version_and_resaves() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo =
            VersionedJsonRepository::<Value>::new(path.clone(), 2).with_migrations(vec![Box::new(
                |value| {
                    Ok(json!({
                        "schema_version": 2,
                        "state": {
                            "phase": value["phase"].clone(),
                        },
                    }))
                },
            )]);
        let state = json!({"schema_version": 1, "phase": "bootstrap"});
        fs::write(&path, serde_json::to_string_pretty(&state).unwrap()).unwrap();

        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["schema_version"], 2);
        assert_eq!(loaded["state"]["phase"], "bootstrap");

        let on_disk: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(on_disk["schema_version"], 2);
        assert_eq!(on_disk["state"]["phase"], "bootstrap");
    }

    #[test]
    fn load_skips_migration_when_version_matches() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let migration_calls = Arc::new(AtomicUsize::new(0));
        let repo =
            VersionedJsonRepository::<Value>::new(path.clone(), 2).with_migrations(vec![Box::new(
                {
                    let migration_calls = Arc::clone(&migration_calls);
                    move |value| {
                        migration_calls.fetch_add(1, Ordering::Relaxed);
                        Ok(value)
                    }
                },
            )]);
        let state = json!({"schema_version": 2, "phase": "bootstrap"});
        fs::write(&path, serde_json::to_string_pretty(&state).unwrap()).unwrap();

        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["phase"], "bootstrap");
        assert_eq!(migration_calls.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn load_supports_migration_chains() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path.clone(), 3).with_migrations(vec![
            Box::new(|value| {
                Ok(json!({
                    "schema_version": 2,
                    "phase": value["phase"].clone(),
                    "preflight": { "status": "pending" },
                }))
            }),
            Box::new(|value| {
                Ok(json!({
                    "schema_version": 3,
                    "state": {
                        "phase": value["phase"].clone(),
                        "preflight": value["preflight"].clone(),
                    },
                }))
            }),
        ]);
        let state = json!({"schema_version": 1, "phase": "bootstrap"});
        fs::write(&path, serde_json::to_string_pretty(&state).unwrap()).unwrap();

        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["schema_version"], 3);
        assert_eq!(loaded["state"]["phase"], "bootstrap");
        assert_eq!(loaded["state"]["preflight"]["status"], "pending");
    }

    #[test]
    fn save_creates_parent_directories() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested").join("dir").join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path, 1);
        let state = json!({"schema_version": 1});
        repo.save(&state).unwrap();
        assert!(repo.path.exists());
    }

    #[test]
    fn save_is_atomic_via_rename() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path, 1);
        let state = json!({"schema_version": 1, "data": "first"});
        repo.save(&state).unwrap();
        let state2 = json!({"schema_version": 1, "data": "second"});
        repo.save(&state2).unwrap();
        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["data"], "second");
    }

    #[test]
    fn update_serializes_concurrent_writers() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let initial = json!({"schema_version": 1, "count": 0});
        VersionedJsonRepository::<Value>::new(path.clone(), 1)
            .save(&initial)
            .unwrap();

        let mut workers = Vec::new();
        for _ in 0..8 {
            let path = path.clone();
            workers.push(thread::spawn(move || {
                let repo = VersionedJsonRepository::<Value>::new(path, 1);
                for _ in 0..25 {
                    repo.update(|current| {
                        let mut next =
                            current.unwrap_or_else(|| json!({"schema_version": 1, "count": 0}));
                        let count = next["count"].as_u64().unwrap();
                        next["count"] = json!(count + 1);
                        Ok(Some(next))
                    })
                    .unwrap();
                }
            }));
        }

        for worker in workers {
            worker.join().unwrap();
        }

        let loaded = VersionedJsonRepository::<Value>::new(path, 1)
            .load()
            .unwrap()
            .unwrap();
        assert_eq!(loaded["count"], 200);
    }

    #[test]
    fn transition_error_displays_message() {
        let err = TransitionError("bad transition".to_string());
        assert_eq!(err.to_string(), "bad transition");
    }

    #[test]
    fn path_accessor_returns_configured_path() {
        let repo = VersionedJsonRepository::<Value>::new(PathBuf::from("/tmp/test.json"), 3);
        assert_eq!(repo.path(), Path::new("/tmp/test.json"));
        assert_eq!(repo.current_version(), 3);
    }
}
