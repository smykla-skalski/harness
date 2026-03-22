use std::collections::HashMap;
use std::env;
use std::path::Path;

use tracing::info;

use crate::errors::CliError;
use crate::infra::exec::cluster_exists;
use crate::setup::services::cluster::{make_target, make_target_live};

/// Helm settings that fix init container CPU throttling on k3d clusters.
///
/// Without these, `kuma-init` containers get CPU-throttled by k3d's default
/// cgroup limits, causing pods to sit at `Init:0/1` for 2-4 minutes. Setting
/// the CPU limit to `0` removes the limit entirely; a small request is kept
/// so the scheduler has a baseline.
pub(super) const INIT_CONTAINER_THROTTLE_FIX: &[&str] = &[
    "runtime.kubernetes.injector.initContainer.resources.limits.cpu=0",
    "runtime.kubernetes.injector.initContainer.resources.requests.cpu=10m",
];

pub(super) fn start_and_deploy(
    root: &Path,
    base_env: &HashMap<String, String>,
    cluster_name: &str,
    kuma_mode: &str,
    extra_settings: &[String],
) -> Result<(), CliError> {
    let mut env = base_env.clone();
    env.insert("CLUSTER".to_string(), cluster_name.to_string());
    if !cluster_exists(cluster_name)? {
        info!(%cluster_name, "starting k3d cluster");
        make_target_live(root, "k3d/cluster/start", &env)?;
        info!(%cluster_name, "k3d cluster ready");
    }
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let kubeconfig = format!("{home}/.kube/k3d-{cluster_name}.yaml");
    env.insert("KUBECONFIG".to_string(), kubeconfig);
    env.insert("K3D_HELM_DEPLOY_NO_CNI".to_string(), "true".to_string());
    env.insert("KUMA_MODE".to_string(), kuma_mode.to_string());

    // Merge existing settings, init container throttle fix, and caller extras.
    let existing = env
        .get("K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS")
        .cloned()
        .unwrap_or_default();
    let mut all: Vec<String> = if existing.is_empty() {
        vec![]
    } else {
        existing.split_whitespace().map(String::from).collect()
    };
    all.extend(INIT_CONTAINER_THROTTLE_FIX.iter().map(|s| (*s).to_string()));
    all.extend(extra_settings.iter().cloned());
    env.insert(
        "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
        all.join(" "),
    );

    info!(%cluster_name, %kuma_mode, "deploying Kuma");
    make_target_live(root, "k3d/cluster/deploy/helm", &env)?;
    info!(%cluster_name, "Kuma deployed");
    Ok(())
}

pub(super) fn cluster_stop(
    root: &Path,
    base_env: &HashMap<String, String>,
    cluster_name: &str,
) -> Result<(), CliError> {
    if !cluster_exists(cluster_name)? {
        println!("cluster {cluster_name} is already absent");
        return Ok(());
    }
    let mut env = base_env.clone();
    env.insert("CLUSTER".to_string(), cluster_name.to_string());
    make_target(root, "k3d/cluster/stop", &env)?;
    Ok(())
}
