use std::path::{Path, PathBuf};

use crate::errors::CliError;

use super::super::CurrentRunPointer;
use super::super::aggregate::RunAggregate;

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
