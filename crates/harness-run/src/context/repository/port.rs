use std::path::Path;

use harness_kernel::errors::CliError;

use super::super::aggregate::RunAggregate;

/// Port for run repository operations, enabling test doubles.
pub trait RunRepositoryPort: Send + Sync {
    /// Load a full run aggregate from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if required files are missing or invalid.
    fn load(&self, run_dir: &Path) -> Result<RunAggregate, CliError>;
}
