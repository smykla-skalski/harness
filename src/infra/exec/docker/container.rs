use std::sync::Arc;

use crate::errors::CliError;
use crate::infra::blocks::{ContainerConfig, StdProcessExecutor, container_runtime_from_env};

use super::super::CommandResult;

/// Start a named Docker container in detached mode. Returns container ID.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_run_detached(
    image: &str,
    name: &str,
    network: &str,
    env: &[(&str, &str)],
    ports: &[(u16, u16)],
    extra_args: &[&str],
    cmd: &[&str],
) -> Result<CommandResult, CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker
        .run_detached(&ContainerConfig {
            image: image.to_string(),
            name: name.to_string(),
            network: network.to_string(),
            env: env
                .iter()
                .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
                .collect(),
            ports: ports.to_vec(),
            labels: vec![],
            entrypoint: None,
            restart_policy: None,
            extra_args: extra_args.iter().map(|arg| (*arg).to_string()).collect(),
            command: cmd.iter().map(|arg| (*arg).to_string()).collect(),
        })
        .map_err(Into::into)
}

/// Stop and remove a named container.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_rm(name: &str) -> Result<CommandResult, CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker.remove(name).map_err(Into::into)
}

/// Get the IP address of a container on a given Docker network.
///
/// # Errors
/// Returns `CliError` on command failure or if the IP cannot be extracted.
pub fn docker_inspect_ip(container: &str, network: &str) -> Result<String, CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker.inspect_ip(container, network).map_err(Into::into)
}

/// Check if a named container exists and is running.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn container_running(name: &str) -> Result<bool, CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker.is_running(name).map_err(Into::into)
}

/// Remove all containers matching a label. Returns the list of removed names.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_rm_by_label(label: &str) -> Result<Vec<String>, CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker.remove_by_label(label).map_err(Into::into)
}

/// Run a command inside a running container.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_exec_cmd(container: &str, cmd: &[&str]) -> Result<CommandResult, CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker.exec_command(container, cmd).map_err(Into::into)
}

/// Run a command inside a running container in detached mode.
///
/// Uses `docker exec -d` so the process runs in the background inside
/// the container without a shell wrapper.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_exec_detached(container: &str, cmd: &[&str]) -> Result<CommandResult, CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker.exec_detached(container, cmd).map_err(Into::into)
}

/// Write `content` to `container_path` inside a running container using `docker cp`.
///
/// Writes to a local temp file then copies it in, avoiding shell interpretation
/// of the content.
///
/// # Errors
/// Returns `CliError` on I/O or `docker cp` failure.
pub fn docker_write_file(
    container: &str,
    container_path: &str,
    content: &str,
) -> Result<(), CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    docker
        .write_file(container, container_path, content)
        .map_err(Into::into)
}
