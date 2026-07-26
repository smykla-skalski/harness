use std::path::Path;
use std::thread;

use serde::de::DeserializeOwned;

use harness_kernel::errors::CliError;
use crate::infra::io::read_json_typed;
use crate::run::RunStatus;

use super::super::aggregate::RunAggregate;
use super::super::{RunLayout, RunMetadata};
use super::port::RunRepositoryPort;

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
            let metadata_thread = scope.spawn(|| read_json_typed::<RunMetadata>(&metadata_path));
            let status_thread = scope.spawn(|| read_json_typed::<RunStatus>(&status_path));
            let suite_thread = scope.spawn(|| Self::load_optional(&prepared_suite_path));
            let preflight_thread = scope.spawn(|| Self::load_optional(&preflight_path));
            let cluster_thread = scope.spawn(|| Self::load_optional(&cluster_path));

            Ok(RunAggregate {
                layout,
                metadata: metadata_thread.join().expect("meta thread panicked")?,
                status: Some(status_thread.join().expect("status thread panicked")?),
                prepared_suite: suite_thread.join().expect("suite thread panicked")?,
                preflight: preflight_thread
                    .join()
                    .expect("preflight thread panicked")?,
                cluster: cluster_thread.join().expect("cluster thread panicked")?,
            })
        })
    }
}

impl RunRepositoryPort for RunRepository {
    fn load(&self, run_dir: &Path) -> Result<RunAggregate, CliError> {
        self.load(run_dir)
    }
}
