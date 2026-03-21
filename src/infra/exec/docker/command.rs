use crate::errors::CliError;

use super::super::CommandResult;
use super::super::k3d;
use super::super::run_command;

/// Run docker.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker(args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["docker"];
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

/// Check if a k3d cluster exists.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn cluster_exists(name: &str) -> Result<bool, CliError> {
    let result = k3d(&["cluster", "list", "--no-headers"], &[0])?;
    Ok(result
        .stdout
        .lines()
        .any(|line| line.split_whitespace().next() == Some(name)))
}
