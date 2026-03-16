use std::path::{Path, PathBuf};
use std::{fs, io};

use serde::de::DeserializeOwned;

use crate::core_defs::current_run_context_path;
use crate::errors::{CliError, CliErrorKind};
use crate::io::{read_json_typed, write_json_pretty};
use crate::schema::RunStatus;

use super::aggregate::RunAggregate;
use super::{CurrentRunPointer, RunLayout, RunMetadata};

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
    pub fn load(&self, run_dir: &Path) -> Result<RunAggregate, CliError> {
        let layout = RunLayout::from_run_dir(run_dir);
        let metadata: RunMetadata = read_json_typed(&layout.metadata_path())?;
        let status: RunStatus = read_json_typed(&layout.status_path())?;
        let prepared_suite = Self::load_optional(&layout.prepared_suite_path())?;
        let preflight = Self::load_optional(&layout.preflight_artifact_path())?;
        let cluster = Self::load_optional(&layout.state_dir().join("cluster.json"))?;

        Ok(RunAggregate {
            layout,
            metadata,
            status: Some(status),
            cluster,
            prepared_suite,
            preflight,
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
