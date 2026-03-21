use std::path::Path;

use crate::errors::CliError;

use super::super::CommandResult;
use super::super::run_command;
use super::super::run_command_streaming;

/// Start services from a compose file with a wait timeout.
///
/// Uses streaming mode so that progress lines (container created, healthy,
/// etc.) are surfaced to the user during long waits.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_up(
    file: &Path,
    project: &str,
    timeout_seconds: u32,
) -> Result<CommandResult, CliError> {
    let file_str = file.to_string_lossy();
    let timeout_str = timeout_seconds.to_string();
    run_command_streaming(
        &[
            "docker",
            "compose",
            "-f",
            &file_str,
            "-p",
            project,
            "up",
            "-d",
            "--wait",
            "--wait-timeout",
            &timeout_str,
        ],
        None,
        None,
        &[0],
    )
}

/// Stop and remove compose services using a compose file.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_down(file: &Path, project: &str) -> Result<CommandResult, CliError> {
    let file_str = file.to_string_lossy();
    run_command(
        &[
            "docker", "compose", "-f", &file_str, "-p", project, "down", "-v",
        ],
        None,
        None,
        &[0],
    )
}

/// Stop and remove compose services by project name only.
///
/// Does not require the original compose file.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_down_project(project: &str) -> Result<CommandResult, CliError> {
    run_command(
        &["docker", "compose", "-p", project, "down", "-v"],
        None,
        None,
        &[0],
    )
}
