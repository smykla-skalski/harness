use std::path::Path;

use crate::cluster::ClusterSpec;
use crate::errors::CliError;
use crate::prepared_suite::PreparedSuiteArtifact;
use crate::runtime::ClusterRuntime;
use crate::schema::RunStatus;

use super::repository::RunRepository;
use super::{PreflightArtifact, RunLayout, RunMetadata};

/// Full run aggregate combining layout, metadata, status, cluster, etc.
#[derive(Debug)]
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

    /// Load from the current session context.
    ///
    /// # Errors
    /// Returns `CliError` when the pointer is corrupt or the referenced
    /// run cannot be loaded.
    pub fn from_current() -> Result<Option<Self>, CliError> {
        let repo = RunRepository;
        repo.load_current()
    }

    /// Build a typed cluster runtime from the aggregate.
    ///
    /// # Errors
    /// Returns `CliError` if cluster runtime details are missing.
    pub fn cluster_runtime(&self) -> Result<ClusterRuntime<'_>, CliError> {
        ClusterRuntime::from_run(self)
    }
}
