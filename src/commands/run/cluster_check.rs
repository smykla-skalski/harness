use serde_json::json;

use clap::Args;

use crate::cluster::{ClusterSpec, Platform};
use crate::commands::RunDirArgs;
use crate::commands::resolve_run_context;
use crate::errors::{CliError, CliErrorKind};
use crate::exec;
use crate::runtime::ClusterRuntime;

/// Arguments for `harness cluster-check`.
#[derive(Debug, Clone, Args)]
pub struct ClusterCheckArgs {
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Check if cluster containers/networks from the persisted cluster spec are still running.
///
/// Outputs JSON with per-member status. Exit 0 if all healthy, exit 1 if any missing.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cluster_check(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let ctx = resolve_run_context(run_dir_args)?;
    let runtime = ctx.cluster_runtime()?;
    let spec = ctx
        .cluster
        .as_ref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster"))?;

    let mut member_statuses = Vec::new();

    match runtime.platform() {
        Platform::Kubernetes => check_kubernetes_members(spec, &mut member_statuses),
        Platform::Universal => check_universal_members(spec, &runtime, &mut member_statuses),
    }

    let all_healthy = member_statuses
        .iter()
        .all(|s| s.get("running").and_then(serde_json::Value::as_bool).unwrap_or(false));

    let mut output = json!({
        "healthy": all_healthy,
        "members": member_statuses,
    });
    if !all_healthy {
        output["hint"] =
            json!("use 'harness logs <name>' to inspect, or re-run 'harness cluster' to recreate");
    }
    let pretty = serde_json::to_string_pretty(&output)
        .map_err(|e| CliErrorKind::serialize(format!("cluster-check: {e}")))?;
    println!("{pretty}");

    if all_healthy { Ok(0) } else { Ok(1) }
}

/// Check Kubernetes cluster members by querying k3d cluster existence.
fn check_kubernetes_members(spec: &ClusterSpec, statuses: &mut Vec<serde_json::Value>) {
    for member in &spec.members {
        let running = exec::cluster_exists(&member.name).unwrap_or(false);
        statuses.push(json!({
            "name": member.name,
            "role": member.role,
            "running": running,
        }));
    }
}

/// Check universal cluster members by querying Docker container status and network.
fn check_universal_members(
    spec: &ClusterSpec,
    runtime: &ClusterRuntime,
    statuses: &mut Vec<serde_json::Value>,
) {
    for member in &spec.members {
        let container_name = runtime.resolve_container_name(&member.name);
        let running = exec::container_running(&container_name).unwrap_or(false);
        statuses.push(json!({
            "name": member.name,
            "container": container_name,
            "role": member.role,
            "running": running,
        }));
    }

    if let Ok(network) = runtime.docker_network() {
        let network_exists = check_docker_network(network);
        statuses.push(json!({
            "name": network,
            "role": "network",
            "running": network_exists,
        }));
    }
}

/// Check whether a Docker network exists by name.
fn check_docker_network(network: &str) -> bool {
    exec::docker(
        &[
            "network",
            "ls",
            "--filter",
            &format!("name=^{network}$"),
            "--format",
            "{{.Name}}",
        ],
        &[0],
    )
    .ok()
    .is_some_and(|result| result.stdout.trim() == network)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn cluster_check_errors_on_nonexistent_run_dir() {
        let args = RunDirArgs {
            run_dir: Some(PathBuf::from("/tmp/harness-test-nonexistent-xyz")),
            run_id: None,
            run_root: None,
        };
        let err = cluster_check(&args).unwrap_err();
        // Should fail when trying to read run metadata from missing dir
        assert!(
            err.code() == "KSRCLI014" || err.code() == "KSRCLI009",
            "unexpected error code: {}",
            err.code()
        );
    }
}
