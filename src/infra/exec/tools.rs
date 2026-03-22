use std::path::Path;

#[cfg(test)]
use tracing::info;

use crate::errors::{CliError, CliErrorKind};

use super::{CommandResult, run_command};

/// Restart all deployments in the given namespaces via `kubectl rollout restart`.
///
/// # Errors
/// Returns `CliError` if any restart command fails.
#[cfg(test)]
pub(crate) fn kubectl_rollout_restart(
    kubeconfig: Option<&Path>,
    namespaces: &[String],
) -> Result<(), CliError> {
    for namespace in namespaces {
        kubectl(
            kubeconfig,
            &["rollout", "restart", "deployment", "-n", namespace],
            &[0],
        )?;
        info!(%namespace, "restarted deployments");
    }
    Ok(())
}

/// Run kubectl with optional kubeconfig.
///
/// # Errors
/// Returns `CliError` on command failure.
#[cfg(test)]
pub(crate) fn kubectl(
    kubeconfig: Option<&Path>,
    args: &[&str],
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["kubectl"];
    let kubeconfig_owned;
    if let Some(path) = kubeconfig {
        kubeconfig_owned = path.to_string_lossy().into_owned();
        command.push("--kubeconfig");
        command.push(&kubeconfig_owned);
    }
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

/// Run k3d.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn k3d(args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["k3d"];
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

/// Run kumactl configured to talk to a CP at the given address.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn kumactl_run(
    binary: &Path,
    cp_addr: &str,
    args: &[&str],
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    use std::io::Write as _;

    let config_content = format!(
        "contexts:\n- controlPlane: harness\n  name: harness\ncurrentContext: harness\ncontrolPlanes:\n- coordinates:\n    apiServer:\n      url: {cp_addr}\n  name: harness\n"
    );
    let mut tmp = tempfile::NamedTempFile::new()
        .map_err(|error| CliErrorKind::io(format!("kumactl config temp: {error}")))?;
    tmp.write_all(config_content.as_bytes())
        .map_err(|error| CliErrorKind::io(format!("write kumactl config: {error}")))?;
    let config_path = tmp.path().to_string_lossy().into_owned();

    let binary_owned = binary.to_string_lossy().into_owned();
    let mut command: Vec<&str> = vec![&binary_owned, "--config-file", &config_path];
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}
