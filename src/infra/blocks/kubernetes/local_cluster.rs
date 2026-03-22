use std::sync::Arc;

use crate::infra::blocks::{BlockError, ProcessExecutor};
use crate::infra::exec::CommandResult;

/// Local disposable cluster operations backed by `k3d`.
pub trait LocalClusterManager: Send + Sync {
    /// Run `k3d`, capturing output.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the command fails.
    fn run(&self, args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, BlockError>;

    /// Check whether a named local cluster exists.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the `k3d` command fails.
    fn cluster_exists(&self, name: &str) -> Result<bool, BlockError>;

    /// Delete or stop a named local cluster.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the operation fails.
    fn stop_cluster(&self, name: &str) -> Result<(), BlockError>;
}

/// Production local-cluster manager backed by `k3d`.
#[cfg(feature = "k3d")]
pub struct K3dClusterManager {
    process: Arc<dyn ProcessExecutor>,
}

#[cfg(feature = "k3d")]
impl K3dClusterManager {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }
}

#[cfg(feature = "k3d")]
impl LocalClusterManager for K3dClusterManager {
    fn run(&self, args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, BlockError> {
        let mut command = vec!["k3d"];
        command.extend_from_slice(args);
        self.process.run(&command, None, None, ok_exit_codes)
    }

    fn cluster_exists(&self, name: &str) -> Result<bool, BlockError> {
        let result = self.run(&["cluster", "list", "--no-headers"], &[0])?;
        Ok(result
            .stdout
            .lines()
            .any(|line| line.split_whitespace().next() == Some(name)))
    }

    fn stop_cluster(&self, name: &str) -> Result<(), BlockError> {
        self.run(&["cluster", "stop", name], &[0])?;
        Ok(())
    }
}
