use serde_json::json;

use crate::cli::RunDirArgs;
use crate::cluster::Platform;
use crate::commands::resolve_run_context;
use crate::errors::{CliError, CliErrorKind};
use crate::exec;

/// Check if cluster containers/networks from the persisted cluster spec are still running.
///
/// Outputs JSON with per-member status. Exit 0 if all healthy, exit 1 if any missing.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cluster_check(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let ctx = resolve_run_context(run_dir_args)?;
    let spec = ctx
        .cluster
        .as_ref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster"))?;

    let mut all_healthy = true;
    let mut member_statuses = Vec::new();

    match spec.platform {
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
                let container_name = if spec.is_compose_managed() {
                    let project = format!(
                        "harness-{}",
                        spec.members.first().map_or("default", |m| m.name.as_str()),
                    );
                    format!("{project}-{}-1", member.name)
                } else {
                    member.name.clone()
                };
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
            if let Some(ref network) = spec.docker_network {
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
                    .is_some_and(|r| r.stdout.trim() == network.as_str());
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

    let output = json!({
        "healthy": all_healthy,
        "members": member_statuses,
    });
    let pretty = serde_json::to_string_pretty(&output)
        .map_err(|e| CliErrorKind::serialize(format!("cluster-check: {e}")))?;
    println!("{pretty}");

    if all_healthy { Ok(0) } else { Ok(1) }
}
