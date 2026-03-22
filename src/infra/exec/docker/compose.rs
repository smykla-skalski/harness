use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use crate::errors::CliError;
use crate::infra::blocks::{StdProcessExecutor, container_backends_from_env};

use super::super::CommandResult;

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
    let runtimes = container_backends_from_env(Arc::new(StdProcessExecutor))?;
    runtimes
        .compose_orchestrator
        .up(
            file,
            project,
            Duration::from_secs(u64::from(timeout_seconds)),
        )
        .map_err(Into::into)
}

/// Stop and remove compose services using a compose file.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_down(file: &Path, project: &str) -> Result<CommandResult, CliError> {
    let runtimes = container_backends_from_env(Arc::new(StdProcessExecutor))?;
    runtimes
        .compose_orchestrator
        .down(file, project)
        .map_err(Into::into)
}

/// Stop and remove compose services by project name only.
///
/// Does not require the original compose file.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_down_project(project: &str) -> Result<CommandResult, CliError> {
    let runtimes = container_backends_from_env(Arc::new(StdProcessExecutor))?;
    runtimes
        .compose_orchestrator
        .down_project(project)
        .map_err(Into::into)
}
