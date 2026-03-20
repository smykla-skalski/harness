use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

mod runtime;

#[cfg(test)]
mod fake;
#[cfg(test)]
mod tests;

pub use runtime::DockerContainerRuntime;

#[cfg(test)]
pub use fake::FakeContainerRuntime;

/// Configuration for starting a detached container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerConfig {
    pub image: String,
    pub name: String,
    pub network: String,
    pub env: Vec<(String, String)>,
    pub ports: Vec<(u16, u16)>,
    pub labels: Vec<(String, String)>,
    pub extra_args: Vec<String>,
    pub command: Vec<String>,
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
    fn create_network(&self, name: &str, subnet: &str) -> Result<(), BlockError>;

    /// Remove a Docker network.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn remove_network(&self, name: &str) -> Result<(), BlockError>;

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
