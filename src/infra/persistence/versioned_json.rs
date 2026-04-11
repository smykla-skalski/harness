use std::ffi::OsStr;
use std::fmt;
use std::marker::PhantomData;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io;
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};

/// Error for invalid state transitions.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct TransitionError(pub String);

/// A boxed migration closure accepted by `with_migrations`.
pub type BoxedMigration = Box<dyn Fn(Value) -> Result<Value, CliError> + Send + Sync>;

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
    pub fn with_migrations(mut self, migrations: Vec<BoxedMigration>) -> Self {
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
        if Self::schema_version(&contents) == self.current_version {
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
        let mut version = Self::schema_version(&contents);
        if version == self.current_version {
            return Ok((contents, false));
        }
        if version == 0 {
            return Err(CliErrorKind::workflow_version(format!(
                "{} is missing schema_version",
                self.path.display()
            ))
            .into());
        }
        if version > self.current_version {
            return Err(CliErrorKind::workflow_version(format!(
                "v{version} is newer than supported v{}",
                self.current_version
            ))
            .into());
        }

        let mut data = contents;
        while version < self.current_version {
            let migration_index = usize::try_from(version - 1).map_err(|error| {
                CliErrorKind::workflow_version(format!(
                    "invalid migration index for v{version}: {error}"
                ))
            })?;
            let migration = self.migrations.get(migration_index).ok_or_else(|| {
                CliErrorKind::workflow_version(format!(
                    "no migration from v{version} to v{} for {}",
                    version + 1,
                    self.path.display()
                ))
            })?;
            data = migration(data)?;

            let next_version = Self::schema_version(&data);
            if next_version != version + 1 {
                return Err(CliErrorKind::workflow_version(format!(
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
            CliErrorKind::workflow_serialize(format!(
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
            CliErrorKind::workflow_io(format!("failed to write {}: {error}", self.path.display()))
                .into()
        })
    }

    fn schema_version(contents: &Value) -> u32 {
        contents
            .get("schema_version")
            .and_then(Value::as_u64)
            .and_then(|version| u32::try_from(version).ok())
            .unwrap_or(0)
    }

    fn workflow_parse_error(&self, error: impl fmt::Display) -> CliError {
        CliErrorKind::workflow_parse(format!("failed to parse {}: {error}", self.path.display()))
            .with_details(error.to_string())
    }

    fn lock_path(&self) -> PathBuf {
        let file_name = self
            .path
            .file_name()
            .and_then(OsStr::to_str)
            .map_or_else(|| "state.json".to_string(), ToString::to_string);
        self.path.with_file_name(format!("{file_name}.lock"))
    }

    fn lock_context() -> FlockErrorContext {
        FlockErrorContext::new("workflow persistence")
    }

    fn with_exclusive_lock<R>(
        &self,
        action: impl FnOnce() -> Result<R, CliError>,
    ) -> Result<R, CliError> {
        with_exclusive_flock(&self.lock_path(), Self::lock_context(), action)
    }
}

#[cfg(test)]
mod tests;
