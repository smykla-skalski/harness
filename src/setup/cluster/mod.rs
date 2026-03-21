pub(crate) mod kubernetes;
#[cfg(feature = "compose")]
pub(crate) mod universal;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::setup::services::cluster::execute_cluster;

impl Execute for ClusterArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        execute_cluster(self)
    }
}

/// Arguments for `harness setup kuma cluster`.
#[derive(Debug, Clone, Args)]
pub struct ClusterArgs {
    /// Cluster lifecycle mode.
    #[arg(value_parser = [
        "single-up", "single-down",
        "global-zone-up", "global-zone-down",
        "global-two-zones-up", "global-two-zones-down",
    ])]
    pub mode: String,
    /// Primary cluster name.
    pub cluster_name: String,
    /// Additional cluster or zone names required by the mode.
    pub extra_cluster_names: Vec<String>,
    /// Deployment platform: kubernetes or universal.
    #[arg(long, default_value = "kubernetes")]
    pub platform: String,
    /// Repo root to run local Kuma build and deploy targets.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Run directory to update deployment state for.
    #[arg(long)]
    pub run_dir: Option<String>,
    /// Extra Helm setting for Kuma deployment; repeat as needed.
    #[arg(long)]
    pub helm_setting: Vec<String>,
    /// Namespace whose workloads to restart after deployment; repeat as needed.
    #[arg(long)]
    pub restart_namespace: Vec<String>,
    /// Store backend for universal mode: memory or postgres.
    #[arg(long, default_value = "memory")]
    pub store: String,
    /// CP container image override for universal mode.
    #[arg(long)]
    pub image: Option<String>,
    /// Skip building images (replaces `HARNESS_BUILD_IMAGES=0`).
    #[arg(long, default_value_t = false)]
    pub no_build: bool,
    /// Skip loading images into k3d clusters (replaces `HARNESS_LOAD_IMAGES=0`).
    #[arg(long, default_value_t = false)]
    pub no_load: bool,
}

/// Manage disposable local clusters (k3d or universal Docker).
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cluster(args: &ClusterArgs) -> Result<i32, CliError> {
    execute_cluster(args)
}

#[cfg(test)]
mod tests;
