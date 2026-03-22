use std::time::Duration;

use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

mod backend;
mod runtime_bollard;
mod runtime_cli;

#[cfg(test)]
mod fake;
#[cfg(test)]
mod tests;

pub use backend::{
    ContainerRuntimeBackend, container_backend_from_env, container_backends_from_env,
    container_runtime_from_env,
};
pub use runtime_bollard::BollardContainerRuntime;
pub use runtime_cli::DockerContainerRuntime;

#[cfg(test)]
pub use fake::FakeContainerRuntime;

/// Configuration for starting a detached container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerConfig {
    pub image: String,
    pub name: String,
    pub network: String,
    pub env: Vec<(String, String)>,
    pub ports: Vec<ContainerPort>,
    pub labels: Vec<(String, String)>,
    pub entrypoint: Option<Vec<String>>,
    pub restart_policy: Option<String>,
    pub extra_args: Vec<String>,
    pub command: Vec<String>,
}

/// Published host port mapping for a container port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerPort {
    pub host_port: Option<u16>,
    pub container_port: u16,
}

impl ContainerPort {
    #[must_use]
    pub const fn fixed(host_port: u16, container_port: u16) -> Self {
        Self {
            host_port: Some(host_port),
            container_port,
        }
    }

    #[must_use]
    pub const fn ephemeral(container_port: u16) -> Self {
        Self {
            host_port: None,
            container_port,
        }
    }
}

/// Snapshot of a container from formatted `docker ps` output.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ContainerSnapshot {
    pub id: Option<String>,
    pub image: Option<String>,
    pub name: Option<String>,
    pub status: Option<String>,
    pub networks: Option<String>,
}

/// Container runtime operations.
pub trait ContainerRuntime: Send + Sync {
    /// Start a detached container.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn run_detached(&self, config: &ContainerConfig) -> Result<CommandResult, BlockError>;

    /// Stop and remove a container by name.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn remove(&self, name: &str) -> Result<CommandResult, BlockError>;

    /// Remove all containers matching a label.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if listing or removal fails.
    fn remove_by_label(&self, label: &str) -> Result<Vec<String>, BlockError>;

    /// Check whether a named container is running.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the inspect command fails.
    fn is_running(&self, name: &str) -> Result<bool, BlockError>;

    /// Get a container IP for a specific network.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the container has no IP on that network.
    fn inspect_ip(&self, container: &str, network: &str) -> Result<String, BlockError>;

    /// Get the first available container IP across attached networks.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the container has no network IP.
    fn inspect_primary_ip(&self, container: &str) -> Result<String, BlockError>;

    /// Resolve the published host port for a container port.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the container port is not published.
    fn inspect_host_port(&self, container: &str, container_port: u16) -> Result<u16, BlockError>;

    /// List containers using formatted `docker ps` output.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the list command fails.
    fn list_formatted(
        &self,
        filter_args: &[&str],
        format_template: &str,
    ) -> Result<CommandResult, BlockError>;

    /// Run a command inside a container and capture output.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn exec_command(&self, container: &str, command: &[&str]) -> Result<CommandResult, BlockError>;

    /// Run a command inside a container in detached mode.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn exec_detached(&self, container: &str, command: &[&str])
    -> Result<CommandResult, BlockError>;

    /// Copy file content into a container.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the temp-file write or `docker cp` fails.
    fn write_file(&self, container: &str, path: &str, content: &str) -> Result<(), BlockError>;

    /// Create a Docker network if it does not already exist.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn create_network_labeled(
        &self,
        name: &str,
        subnet: &str,
        labels: &[(String, String)],
    ) -> Result<(), BlockError>;

    /// Create a Docker network without extra labels.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn create_network(&self, name: &str, subnet: &str) -> Result<(), BlockError> {
        self.create_network_labeled(name, subnet, &[])
    }

    /// Check whether a named network exists.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the backend query fails.
    fn network_exists(&self, name: &str) -> Result<bool, BlockError>;

    /// Remove a Docker network.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn remove_network(&self, name: &str) -> Result<(), BlockError>;

    /// Remove all networks matching a label.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if listing or removal fails.
    fn remove_networks_by_label(&self, label: &str) -> Result<Vec<String>, BlockError>;

    /// Wait for a container to become healthy or, if no healthcheck exists, running.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if inspection fails or the timeout expires.
    fn wait_healthy(&self, container: &str, timeout: Duration) -> Result<(), BlockError>;

    /// Get container logs.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn logs(&self, container: &str, args: &[&str]) -> Result<CommandResult, BlockError>;

    /// Follow container logs using inherited stdio.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn logs_follow(&self, container: &str, args: &[&str]) -> Result<i32, BlockError>;
}
