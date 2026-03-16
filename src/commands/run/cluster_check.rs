use serde_json::json;

use clap::Args;

use crate::cluster::Platform;
use crate::commands::RunDirArgs;
use crate::commands::resolve_run_context;
use crate::errors::{CliError, CliErrorKind};
use crate::exec;

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

    let mut all_healthy = true;
    let mut member_statuses = Vec::new();

    match runtime.platform() {
        Platform::Kubernetes => {
            for member in &spec.members {
                let running = exec::cluster_exists(&member.name).unwrap_or(false);
                if !running {
                    all_healthy = false;
                }
                member_statuses.push(json!({
                    "name": member.name,
                    "role": member.role,
                    "running": running,
                }));
            }
        }
        Platform::Universal => {
            for member in &spec.members {
                let container_name = runtime.resolve_container_name(&member.name);
                let running = exec::container_running(&container_name).unwrap_or(false);
                if !running {
                    all_healthy = false;
                }
                member_statuses.push(json!({
                    "name": member.name,
                    "container": container_name,
                    "role": member.role,
                    "running": running,
                }));
            }

            // Check network
            if let Ok(network) = runtime.docker_network() {
                let net_check = exec::docker(
                    &[
                        "network",
                        "ls",
                        "--filter",
                        &format!("name=^{network}$"),
                        "--format",
                        "{{.Name}}",
                    ],
                    &[0],
                );
                let network_exists = net_check
                    .ok()
                    .is_some_and(|result| result.stdout.trim() == network);
                if !network_exists {
                    all_healthy = false;
                }
                member_statuses.push(json!({
                    "name": network,
                    "role": "network",
                    "running": network_exists,
                }));
            }
        }
    }

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
