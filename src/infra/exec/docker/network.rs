use crate::errors::CliError;

use super::command::docker;

/// Create a Docker network if it does not already exist.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_network_create(name: &str, subnet: &str) -> Result<(), CliError> {
    let check = docker(
        &[
            "network",
            "ls",
            "--filter",
            &format!("name=^{name}$"),
            "--format",
            "{{.Name}}",
        ],
        &[0],
    )?;
    if check.stdout.trim() == name {
        return Ok(());
    }
    docker(&["network", "create", "--subnet", subnet, name], &[0])?;
    Ok(())
}

/// Remove a Docker network.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_network_rm(name: &str) -> Result<(), CliError> {
    docker(&["network", "rm", name], &[0, 1])?;
    Ok(())
}
