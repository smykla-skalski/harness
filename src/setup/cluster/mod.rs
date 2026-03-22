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
    /// Kubernetes provider: local k3d or remote kubeconfig-backed clusters.
    #[arg(long, value_parser = ["k3d", "remote"])]
    pub provider: Option<String>,
    /// Repo root to run local Kuma build and deploy targets.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Run directory to update deployment state for.
    #[arg(long)]
    pub run_dir: Option<String>,
    /// Extra Helm setting for Kuma deployment; repeat as needed.
    #[arg(long)]
    pub helm_setting: Vec<String>,
    /// Remote cluster mapping: `name=<cluster>,kubeconfig=<path>[,context=<ctx>]`.
    #[arg(long = "remote", value_parser = parse_remote_target)]
    pub remote: Vec<RemoteClusterTarget>,
    /// Registry/repository prefix used for remote image publishing.
    #[arg(long)]
    pub push_prefix: Option<String>,
    /// Tag used for remote image publishing.
    #[arg(long)]
    pub push_tag: Option<String>,
    /// Namespace for remote Helm releases.
    #[arg(long, default_value = "kuma-system")]
    pub namespace: String,
    /// Helm release name for remote deployments.
    #[arg(long, default_value = "kuma")]
    pub release_name: String,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteClusterTarget {
    pub name: String,
    pub kubeconfig: String,
    pub context: Option<String>,
}

fn parse_remote_target(raw: &str) -> Result<RemoteClusterTarget, String> {
    let mut name = None;
    let mut kubeconfig = None;
    let mut context = None;

    for entry in raw.split(',') {
        let (key, value) = entry
            .split_once('=')
            .ok_or_else(|| format!("invalid --remote entry: {raw}"))?;
        let value = value.trim();
        if value.is_empty() {
            return Err(format!("invalid --remote entry: {raw}"));
        }
        match key.trim() {
            "name" => name = Some(value.to_string()),
            "kubeconfig" => kubeconfig = Some(value.to_string()),
            "context" => context = Some(value.to_string()),
            other => return Err(format!("unsupported --remote key `{other}` in {raw}")),
        }
    }

    Ok(RemoteClusterTarget {
        name: name.ok_or_else(|| format!("missing `name` in --remote entry: {raw}"))?,
        kubeconfig: kubeconfig
            .ok_or_else(|| format!("missing `kubeconfig` in --remote entry: {raw}"))?,
        context,
    })
}

/// Manage harness-tracked Kubernetes or universal cluster lifecycles.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cluster(args: &ClusterArgs) -> Result<i32, CliError> {
    execute_cluster(args)
}

#[cfg(test)]
mod tests;
