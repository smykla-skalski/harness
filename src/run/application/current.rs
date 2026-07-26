use std::path::PathBuf;

use crate::run::context::RunRepository;
use harness_kernel::errors::CliError;

use super::RunApplication;

impl RunApplication {
    /// Return the active tracked run directory when one is selected.
    ///
    /// # Errors
    /// Returns `CliError` when the current-run pointer cannot be loaded.
    pub fn current_run_dir() -> Result<Option<PathBuf>, CliError> {
        let repo = RunRepository;
        Ok(repo
            .load_current_pointer()?
            .map(|pointer| pointer.layout.run_dir()))
    }

    /// Clear the active current-run pointer.
    ///
    /// # Errors
    /// Returns `CliError` when pointer persistence fails.
    pub fn clear_current_pointer() -> Result<(), CliError> {
        let repo = RunRepository;
        repo.clear_current_pointer()
    }
}
