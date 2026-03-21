use std::env;
use std::path::Path;

use tracing::info;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::{docker, kubectl};

/// Resolve the KDS address for a global CP running in a k3d cluster.
///
/// Discovers the k3d server node IP via `docker inspect` and the
/// `kuma-global-zone-sync` service `NodePort` via `kubectl`, then
/// returns `grpcs://<node-ip>:<node-port>`.
pub(super) fn resolve_kds_address(global_cluster: &str) -> Result<String, CliError> {
    let node_container = format!("k3d-{global_cluster}-server-0");
    let format_string = "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}";
    let ip_result = docker(&["inspect", "-f", format_string, &node_container], &[0])?;
    let node_ip = ip_result.stdout.trim().to_string();
    if node_ip.is_empty() {
        return Err(CliErrorKind::cluster_error(format!(
            "could not resolve IP for k3d node {node_container}"
        ))
        .into());
    }

    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let kubeconfig = format!("{home}/.kube/kind-{global_cluster}-config");
    let kubeconfig_path = Path::new(&kubeconfig);
    let port_result = kubectl(
        Some(kubeconfig_path),
        &[
            "get",
            "svc",
            "-n",
            "kuma-system",
            "kuma-global-zone-sync",
            "-o",
            "jsonpath={.spec.ports[?(@.name==\"global-zone-sync\")].nodePort}",
        ],
        &[0],
    )?;
    let node_port = port_result.stdout.trim().to_string();
    if node_port.is_empty() {
        return Err(CliErrorKind::cluster_error(format!(
            "could not resolve KDS NodePort for global cluster {global_cluster}"
        ))
        .into());
    }

    let address = format!("grpcs://{node_ip}:{node_port}");
    info!(%address, "resolved global KDS address");
    Ok(address)
}
