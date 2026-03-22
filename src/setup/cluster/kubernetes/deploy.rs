use std::collections::HashMap;
use std::env;
use std::path::Path;

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
    let env = deploy_env(base_env, cluster_name, kuma_mode, extra_settings);
    ensure_cluster_started(root, &env, cluster_name)?;
    make_target_live(root, "k3d/cluster/deploy/helm", &env)
}

fn deploy_env(
    base_env: &HashMap<String, String>,
    cluster_name: &str,
    kuma_mode: &str,
    extra_settings: &[String],
) -> HashMap<String, String> {
    let mut env = base_env.clone();
    env.insert("CLUSTER".to_string(), cluster_name.to_string());
    env.insert("KUBECONFIG".to_string(), cluster_kubeconfig(cluster_name));
    env.insert("K3D_HELM_DEPLOY_NO_CNI".to_string(), "true".to_string());
    env.insert("KUMA_MODE".to_string(), kuma_mode.to_string());
    env.insert(
        "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
        merged_deploy_settings(&env, extra_settings).join(" "),
    );
    env
}

fn cluster_kubeconfig(cluster_name: &str) -> String {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    format!("{home}/.kube/k3d-{cluster_name}.yaml")
}

fn merged_deploy_settings(env: &HashMap<String, String>, extra_settings: &[String]) -> Vec<String> {
    let mut all = existing_deploy_settings(env);
    all.extend(INIT_CONTAINER_THROTTLE_FIX.iter().map(|s| (*s).to_string()));
    all.extend(extra_settings.iter().cloned());
    all
}

fn existing_deploy_settings(env: &HashMap<String, String>) -> Vec<String> {
    env.get("K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS")
        .map_or_else(Vec::new, |existing| {
            existing.split_whitespace().map(String::from).collect()
        })
}

fn ensure_cluster_started(
    root: &Path,
    env: &HashMap<String, String>,
    cluster_name: &str,
) -> Result<(), CliError> {
    if cluster_exists(cluster_name)? {
        return Ok(());
    }
    make_target_live(root, "k3d/cluster/start", env)
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
