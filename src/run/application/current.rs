use std::path::Path;
use std::path::PathBuf;

use crate::errors::CliError;
use crate::infra::io::write_json_pretty;
use crate::kernel::topology::ClusterSpec;
use crate::run::context::{CurrentRunPointer, RunContext, RunRepository};

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

    /// Load the persisted cluster spec from the active current-run pointer.
    ///
    /// # Errors
    /// Returns `CliError` when the pointer cannot be loaded.
    pub fn load_current_cluster_spec() -> Result<Option<ClusterSpec>, CliError> {
        let repo = RunRepository;
        Ok(repo
            .load_current_pointer()?
            .and_then(|pointer| pointer.cluster))
    }

    /// Persist a cluster spec into run-owned state for the active tracked run.
    ///
    /// # Errors
    /// Returns `CliError` when pointer or state persistence fails.
    pub fn persist_current_cluster_spec(spec: &ClusterSpec) -> Result<(), CliError> {
        let repo = RunRepository;
        if let Some(pointer) = repo.load_current_pointer()? {
            let run_dir = pointer.layout.run_dir();
            let _ = repo.update_current_pointer(|record| {
                record.cluster = Some(spec.clone());
            })?;

            let state_dir = run_dir.join("state");
            if state_dir.is_dir() {
                let cluster_path = state_dir.join("cluster.json");
                write_json_pretty(&cluster_path, spec)?;
            }
        }
        Ok(())
    }

    /// Persist this run as the active current-run pointer.
    ///
    /// # Errors
    /// Returns `CliError` when pointer persistence fails.
    pub fn save_as_current(&self) -> Result<(), CliError> {
        let pointer = CurrentRunPointer::from_metadata(
            self.layout().clone(),
            self.metadata(),
            self.context().cluster.clone(),
        );
        let repo = RunRepository;
        repo.save_current_pointer(&pointer)
    }

    /// Build the application boundary from a loaded run context.
    #[must_use]
    pub fn from_context(ctx: RunContext) -> Self {
        Self {
            services: super::RunServices::from_context(ctx),
        }
    }

    /// Build the application boundary from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if the run context cannot be loaded.
    pub fn from_run_dir(run_dir: &Path) -> Result<Self, CliError> {
        Ok(Self::from_context(RunContext::from_run_dir(run_dir)?))
    }

    /// Build the application boundary from the current session run pointer.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer or referenced run is invalid.
    pub fn from_current() -> Result<Option<Self>, CliError> {
        Ok(RunContext::from_current()?.map(Self::from_context))
    }
}
