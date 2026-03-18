#[cfg(test)]
use std::collections;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync;
use std::thread;
use std::{fs, io};

use serde::de::DeserializeOwned;

use crate::core_defs::current_run_context_path;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::schema::RunStatus;

use super::aggregate::RunAggregate;
use super::{CurrentRunPointer, RunLayout, RunMetadata};

/// Port for run repository operations, enabling test doubles.
pub trait RunRepositoryPort: Send + Sync {
    /// Load a full run aggregate from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if required files are missing or invalid.
    fn load(&self, run_dir: &Path) -> Result<RunAggregate, CliError>;

    /// Load the current run pointer from the session context directory.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer path cannot be resolved, read, or parsed.
    fn load_current_pointer(&self) -> Result<Option<CurrentRunPointer>, CliError>;

    /// Save the current run pointer to the session context directory.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer path cannot be created or written.
    fn save_current_pointer(&self, pointer: &CurrentRunPointer) -> Result<(), CliError>;

    /// Update the current run pointer in place when one exists.
    ///
    /// Returns `Ok(false)` when no pointer exists.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer cannot be loaded or saved.
    fn update_current_pointer(
        &self,
        update: &dyn Fn(&mut CurrentRunPointer),
    ) -> Result<bool, CliError>;

    /// Remove the current run pointer from the session context directory.
    ///
    /// # Errors
    /// Returns `CliError` on filesystem failures other than not-found.
    fn clear_current_pointer(&self) -> Result<(), CliError>;

    /// Load a full run aggregate from a persisted pointer.
    ///
    /// # Errors
    /// Returns `CliError` if the referenced run directory is missing or invalid.
    fn load_from_pointer(&self, pointer: CurrentRunPointer) -> Result<RunAggregate, CliError>;

    /// Load the current run aggregate from the session pointer.
    ///
    /// # Errors
    /// Returns `CliError` when the pointer is corrupt or the referenced run cannot be loaded.
    fn load_current(&self) -> Result<Option<RunAggregate>, CliError>;

    /// Resolve the current run directory from the persisted session pointer.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer is corrupt or points at a missing run.
    fn current_run_dir(&self) -> Result<Option<PathBuf>, CliError>;
}

/// Repository for loading persisted run state.
#[derive(Debug, Clone, Copy, Default)]
pub struct RunRepository;

impl RunRepository {
    fn load_optional<T>(path: &Path) -> Result<Option<T>, CliError>
    where
        T: DeserializeOwned,
    {
        if path.exists() {
            return read_json_typed(path).map(Some);
        }
        Ok(None)
    }

    /// Load a full run aggregate from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if required files are missing or invalid.
    ///
    /// # Panics
    /// Panics if an internal file-reading thread panics (should not happen).
    pub fn load(&self, run_dir: &Path) -> Result<RunAggregate, CliError> {
        let layout = RunLayout::from_run_dir(run_dir);
        let metadata_path = layout.metadata_path();
        let status_path = layout.status_path();
        let prepared_suite_path = layout.prepared_suite_path();
        let preflight_path = layout.preflight_artifact_path();
        let cluster_path = layout.state_dir().join("cluster.json");

        thread::scope(|scope| {
            let t_meta = scope.spawn(|| read_json_typed::<RunMetadata>(&metadata_path));
            let t_status = scope.spawn(|| read_json_typed::<RunStatus>(&status_path));
            let t_suite = scope.spawn(|| Self::load_optional(&prepared_suite_path));
            let t_preflight = scope.spawn(|| Self::load_optional(&preflight_path));
            let t_cluster = scope.spawn(|| Self::load_optional(&cluster_path));

            Ok(RunAggregate {
                layout,
                metadata: t_meta.join().expect("meta thread panicked")?,
                status: Some(t_status.join().expect("status thread panicked")?),
                prepared_suite: t_suite.join().expect("suite thread panicked")?,
                preflight: t_preflight.join().expect("preflight thread panicked")?,
                cluster: t_cluster.join().expect("cluster thread panicked")?,
            })
        })
    }

    /// Load the current run pointer from the session context directory.
    ///
    /// Missing pointer files return `Ok(None)`. Corrupt pointers are reported
    /// as explicit load errors instead of being treated as absent.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer path cannot be resolved, read, or parsed.
    pub fn load_current_pointer(&self) -> Result<Option<CurrentRunPointer>, CliError> {
        let pointer_path = current_run_context_path()?;
        if !pointer_path.exists() {
            return Ok(None);
        }
        let pointer = read_json_typed(&pointer_path)?;
        Ok(Some(pointer))
    }

    /// Save the current run pointer to the session context directory.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer path cannot be created or written.
    pub fn save_current_pointer(&self, pointer: &CurrentRunPointer) -> Result<(), CliError> {
        let pointer_path = current_run_context_path()?;
        if let Some(parent) = pointer_path.parent() {
            fs::create_dir_all(parent)?;
        }
        write_json_pretty(&pointer_path, pointer)
    }

    /// Update the current run pointer in place when one exists.
    ///
    /// Returns `Ok(false)` when no pointer exists.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer cannot be loaded or saved.
    pub fn update_current_pointer(
        &self,
        update: impl FnOnce(&mut CurrentRunPointer),
    ) -> Result<bool, CliError> {
        let Some(mut pointer) = self.load_current_pointer()? else {
            return Ok(false);
        };
        update(&mut pointer);
        self.save_current_pointer(&pointer)?;
        Ok(true)
    }

    /// Remove the current run pointer from the session context directory.
    ///
    /// Missing pointer files are ignored.
    ///
    /// # Errors
    /// Returns `CliError` on filesystem failures other than not-found.
    pub fn clear_current_pointer(&self) -> Result<(), CliError> {
        let pointer_path = current_run_context_path()?;
        match fs::remove_file(pointer_path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    /// Load a full run aggregate from a persisted pointer.
    ///
    /// # Errors
    /// Returns `CliError` if the referenced run directory is missing or invalid.
    pub fn load_from_pointer(&self, pointer: CurrentRunPointer) -> Result<RunAggregate, CliError> {
        let run_dir = pointer.layout.run_dir();
        let mut aggregate = self.load(&run_dir)?;
        if aggregate.cluster.is_none() {
            aggregate.cluster = pointer.cluster;
        }
        Ok(aggregate)
    }

    /// Load the current run aggregate from the session pointer.
    ///
    /// # Errors
    /// Returns `CliError` when the pointer is corrupt or the referenced
    /// run cannot be loaded.
    pub fn load_current(&self) -> Result<Option<RunAggregate>, CliError> {
        let Some(pointer) = self.load_current_pointer()? else {
            return Ok(None);
        };
        if !pointer.layout.run_dir().is_dir() {
            return Err(
                CliErrorKind::missing_file(pointer.layout.run_dir().display().to_string()).into(),
            );
        }
        self.load_from_pointer(pointer).map(Some)
    }

    /// Resolve the current run directory from the persisted session pointer.
    ///
    /// Missing pointers return `Ok(None)`. Stale pointers surface as explicit
    /// missing-file errors instead of being treated as absent.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer is corrupt or points at a missing run.
    pub fn current_run_dir(&self) -> Result<Option<PathBuf>, CliError> {
        let Some(pointer) = self.load_current_pointer()? else {
            return Ok(None);
        };
        let run_dir = pointer.layout.run_dir();
        if !run_dir.is_dir() {
            return Err(CliErrorKind::missing_file(run_dir.display().to_string()).into());
        }
        Ok(Some(run_dir))
    }
}

impl RunRepositoryPort for RunRepository {
    fn load(&self, run_dir: &Path) -> Result<RunAggregate, CliError> {
        self.load(run_dir)
    }

    fn load_current_pointer(&self) -> Result<Option<CurrentRunPointer>, CliError> {
        self.load_current_pointer()
    }

    fn save_current_pointer(&self, pointer: &CurrentRunPointer) -> Result<(), CliError> {
        self.save_current_pointer(pointer)
    }

    fn update_current_pointer(
        &self,
        update: &dyn Fn(&mut CurrentRunPointer),
    ) -> Result<bool, CliError> {
        let Some(mut pointer) = self.load_current_pointer()? else {
            return Ok(false);
        };
        update(&mut pointer);
        self.save_current_pointer(&pointer)?;
        Ok(true)
    }

    fn clear_current_pointer(&self) -> Result<(), CliError> {
        self.clear_current_pointer()
    }

    fn load_from_pointer(&self, pointer: CurrentRunPointer) -> Result<RunAggregate, CliError> {
        self.load_from_pointer(pointer)
    }

    fn load_current(&self) -> Result<Option<RunAggregate>, CliError> {
        self.load_current()
    }

    fn current_run_dir(&self) -> Result<Option<PathBuf>, CliError> {
        self.current_run_dir()
    }
}

/// In-memory run repository for tests - stores aggregates and pointers without filesystem.
#[cfg(test)]
pub struct InMemoryRunRepository {
    aggregates: sync::Mutex<collections::HashMap<PathBuf, RunAggregate>>,
    pointer: sync::Mutex<Option<CurrentRunPointer>>,
}

#[cfg(test)]
impl Default for InMemoryRunRepository {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
impl InMemoryRunRepository {
    #[must_use]
    pub fn new() -> Self {
        Self {
            aggregates: sync::Mutex::new(collections::HashMap::new()),
            pointer: sync::Mutex::new(None),
        }
    }

    pub fn insert(&self, run_dir: PathBuf, aggregate: RunAggregate) {
        self.aggregates
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner)
            .insert(run_dir, aggregate);
    }

    pub fn set_pointer(&self, pointer: CurrentRunPointer) {
        *self
            .pointer
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner) = Some(pointer);
    }
}

#[cfg(test)]
impl RunRepositoryPort for InMemoryRunRepository {
    fn load(&self, run_dir: &Path) -> Result<RunAggregate, CliError> {
        self.aggregates
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner)
            .get(run_dir)
            .cloned()
            .ok_or_else(|| CliErrorKind::missing_file(run_dir.display().to_string()).into())
    }

    fn load_current_pointer(&self) -> Result<Option<CurrentRunPointer>, CliError> {
        Ok(self
            .pointer
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner)
            .clone())
    }

    fn save_current_pointer(&self, pointer: &CurrentRunPointer) -> Result<(), CliError> {
        *self
            .pointer
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner) = Some(pointer.clone());
        Ok(())
    }

    fn update_current_pointer(
        &self,
        update: &dyn Fn(&mut CurrentRunPointer),
    ) -> Result<bool, CliError> {
        let mut guard = self
            .pointer
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner);
        let Some(ref mut pointer) = *guard else {
            return Ok(false);
        };
        update(pointer);
        Ok(true)
    }

    fn clear_current_pointer(&self) -> Result<(), CliError> {
        *self
            .pointer
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner) = None;
        Ok(())
    }

    fn load_from_pointer(&self, pointer: CurrentRunPointer) -> Result<RunAggregate, CliError> {
        self.load(&pointer.layout.run_dir())
    }

    fn load_current(&self) -> Result<Option<RunAggregate>, CliError> {
        let Some(pointer) = self.load_current_pointer()? else {
            return Ok(None);
        };
        self.load_from_pointer(pointer).map(Some)
    }

    fn current_run_dir(&self) -> Result<Option<PathBuf>, CliError> {
        let Some(pointer) = self.load_current_pointer()? else {
            return Ok(None);
        };
        Ok(Some(pointer.layout.run_dir()))
    }
}
