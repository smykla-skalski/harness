use std::env;
use std::path::Path;
use std::sync::Arc;

use tracing::info;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::{
    KubernetesRuntime, StdProcessExecutor, container_runtime_from_env, kubernetes_runtime_from_env,
};

/// Resolve the KDS address for a global CP running in a k3d cluster.
///
/// Discovers the k3d server node IP via `docker inspect` and the
/// `kuma-global-zone-sync` service `NodePort` via `kubectl`, then
/// returns `grpcs://<node-ip>:<node-port>`.
pub(super) fn resolve_kds_address(global_cluster: &str) -> Result<String, CliError> {
    let node_container = format!("k3d-{global_cluster}-server-0");
    let process = Arc::new(StdProcessExecutor);
    let docker = container_runtime_from_env(process.clone())?;
    let kubernetes = kubernetes_runtime_from_env(process)?;
    let node_ip = resolve_node_ip(docker.inspect_primary_ip(&node_container)?, &node_container)?;

    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let kubeconfig = format!("{home}/.kube/k3d-{global_cluster}.yaml");
    let kubeconfig_path = Path::new(&kubeconfig);
    let node_port = resolve_kds_node_port(kubernetes.as_ref(), kubeconfig_path, global_cluster)?;

    let address = format!("grpcs://{node_ip}:{node_port}");
    info!(%address, "resolved global KDS address");
    Ok(address)
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
