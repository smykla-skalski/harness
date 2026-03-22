use std::env;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tracing::info;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::{
    ContainerRuntime, KubernetesRuntime, StdProcessExecutor, container_runtime_from_env,
    kubernetes_runtime_from_env,
};

/// Resolve the KDS address for a global CP running in a k3d cluster.
///
/// Discovers the k3d server node IP via `docker inspect` and the
/// `kuma-global-zone-sync` service `NodePort` via `kubectl`, then
/// returns `grpcs://<node-ip>:<node-port>`.
pub(super) fn resolve_kds_address(global_cluster: &str) -> Result<String, CliError> {
    let (docker, kubernetes) = resolve_cluster_runtimes()?;
    let node_container = k3d_server_node(global_cluster);
    let node_ip = resolve_node_ip(docker.inspect_primary_ip(&node_container)?, &node_container)?;
    let kubeconfig = tracked_k3d_kubeconfig(global_cluster);
    let node_port = resolve_kds_node_port(kubernetes.as_ref(), &kubeconfig, global_cluster)?;
    let address = format!("grpcs://{node_ip}:{node_port}");
    info!(%address, "resolved global KDS address");
    Ok(address)
}

fn resolve_cluster_runtimes()
-> Result<(Arc<dyn ContainerRuntime>, Arc<dyn KubernetesRuntime>), CliError> {
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

fn resolve_node_ip(node_ip: String, node_container: &str) -> Result<String, CliError> {
    if node_ip.is_empty() {
        return Err(CliErrorKind::cluster_error(format!(
            "could not resolve IP for k3d node {node_container}"
        ))
        .into());
    }
    Ok(node_ip)
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
