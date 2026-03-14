use std::path::Path;

use crate::core_defs::CommandResult;
use crate::errors::CliError;

/// Run a command via `std::process::Command`, capturing stdout/stderr.
///
/// # Errors
/// Returns `CliError` if the exit code is not in `ok_exit_codes`.
pub fn run_command(
    _args: &[&str],
    _cwd: Option<&Path>,
    _env: Option<&std::collections::HashMap<String, String>>,
    _ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    todo!()
}

/// Run kubectl with optional kubeconfig.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn kubectl(
    _kubeconfig: Option<&Path>,
    _args: &[&str],
    _ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    todo!()
}

/// Run k3d.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn k3d(_args: &[&str], _ok_exit_codes: &[i32]) -> Result<CommandResult, CliError> {
    todo!()
}

/// Run docker.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker(_args: &[&str], _ok_exit_codes: &[i32]) -> Result<CommandResult, CliError> {
    todo!()
}

/// Check if a k3d cluster exists.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn cluster_exists(_name: &str) -> Result<bool, CliError> {
    todo!()
}

#[cfg(test)]
mod tests {}
