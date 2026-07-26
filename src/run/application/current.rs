use std::path::PathBuf;

use crate::infra::io::write_json_pretty;
use crate::run::context::RunRepository;
use harness_kernel::errors::CliError;
use harness_kernel::kernel::topology::ClusterSpec;

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
}
