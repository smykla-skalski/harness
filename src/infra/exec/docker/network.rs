use std::sync::Arc;

use crate::errors::CliError;
use crate::infra::blocks::{StdProcessExecutor, container_runtime_from_env};

/// Create a Docker network if it does not already exist.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_network_create(name: &str, subnet: &str) -> Result<(), CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker.create_network(name, subnet).map_err(Into::into)
}

/// Remove a Docker network.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_network_rm(name: &str) -> Result<(), CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker.remove_network(name).map_err(Into::into)
}
