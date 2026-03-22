use std::env;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::{
    ContainerRuntime, KubernetesRuntime, StdProcessExecutor, container_runtime_from_env,
    kubernetes_runtime_from_env,
};

type ClusterRuntimes = (Arc<dyn ContainerRuntime>, Arc<dyn KubernetesRuntime>);

/// Resolve the KDS address for a global CP running in a k3d cluster.
///
/// Discovers the k3d server node IP via `docker inspect` and the
/// `kuma-global-zone-sync` service `NodePort` via `kubectl`, then
/// returns `grpcs://<node-ip>:<node-port>`.
pub(super) fn resolve_kds_address(global_cluster: &str) -> Result<String, CliError> {
    let (docker, kubernetes) = resolve_cluster_runtimes()?;
    let node_ip = resolve_cluster_node_ip(docker.as_ref(), global_cluster)?;
    let node_port = resolve_cluster_node_port(kubernetes.as_ref(), global_cluster)?;
    Ok(format_kds_address(&node_ip, &node_port))
}

fn resolve_cluster_runtimes() -> Result<ClusterRuntimes, CliError> {
    let process = Arc::new(StdProcessExecutor);
    let docker = container_runtime_from_env(process.clone())?;
    let kubernetes = kubernetes_runtime_from_env(process)?;
    Ok((docker, kubernetes))
}

fn k3d_server_node(global_cluster: &str) -> String {
    format!("k3d-{global_cluster}-server-0")
}

fn tracked_k3d_kubeconfig(global_cluster: &str) -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    Path::new(&home)
        .join(".kube")
        .join(format!("k3d-{global_cluster}.yaml"))
}

fn resolve_cluster_node_ip(
    docker: &dyn ContainerRuntime,
    global_cluster: &str,
) -> Result<String, CliError> {
    let node_container = k3d_server_node(global_cluster);
    resolve_node_ip(docker.inspect_primary_ip(&node_container)?, &node_container)
}

fn resolve_node_ip(node_ip: String, node_container: &str) -> Result<String, CliError> {
    if node_ip.is_empty() {
        return Err(CliErrorKind::cluster_error(format!(
            "could not resolve IP for k3d node {node_container}"
        ))
        .into());
    }
    Ok(node_ip)
}

fn resolve_cluster_node_port(
    kubernetes: &dyn KubernetesRuntime,
    global_cluster: &str,
) -> Result<String, CliError> {
    let kubeconfig = tracked_k3d_kubeconfig(global_cluster);
    resolve_kds_node_port(kubernetes, &kubeconfig, global_cluster)
}

fn resolve_kds_node_port(
    kubernetes: &dyn KubernetesRuntime,
    kubeconfig: &Path,
    global_cluster: &str,
) -> Result<String, CliError> {
    kubernetes
        .service_node_port(
            kubeconfig,
            "kuma-system",
            "kuma-global-zone-sync",
            "global-zone-sync",
        )?
        .map(|port| port.to_string())
        .filter(|port| !port.is_empty())
        .ok_or_else(|| {
            CliErrorKind::cluster_error(format!(
                "could not resolve KDS NodePort for global cluster {global_cluster}"
            ))
            .into()
        })
}

fn format_kds_address(node_ip: &str, node_port: &str) -> String {
    format!("grpcs://{node_ip}:{node_port}")
}
