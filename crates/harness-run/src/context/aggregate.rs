use std::path::Path;

use crate::RunStatus;
use crate::prepared_suite::PreparedSuiteArtifact;
use harness_kernel::errors::CliError;
use harness_kernel::kernel::topology::ClusterSpec;

use super::repository::RunRepository;
use super::{PreflightArtifact, RunLayout, RunMetadata};

/// Full run aggregate combining layout, metadata, status, cluster, etc.
#[derive(Debug, Clone)]
pub struct RunAggregate {
    pub layout: RunLayout,
    pub metadata: RunMetadata,
    pub status: Option<RunStatus>,
    pub cluster: Option<ClusterSpec>,
    pub prepared_suite: Option<PreparedSuiteArtifact>,
    pub preflight: Option<PreflightArtifact>,
}

pub type RunContext = RunAggregate;

impl RunAggregate {
    /// Load from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if required files are missing or invalid.
    pub fn from_run_dir(run_dir: &Path) -> Result<Self, CliError> {
        let repo = RunRepository;
        repo.load(run_dir)
    }
}
