mod helpers;
mod runtime;
mod support;

#[cfg(test)]
mod error_tests;

use std::time::Duration;

use bollard::Docker;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;

/// Production container runtime backed by the Docker Engine API via Bollard.
pub struct BollardContainerRuntime {
    docker: Docker,
}

impl BollardContainerRuntime {
    const REMOVE_TIMEOUT: Duration = Duration::from_secs(5);
    const REMOVE_POLL_INTERVAL: Duration = Duration::from_millis(100);

    /// Create a runtime connected to the local Docker Engine API.
    ///
    /// # Errors
    ///
    /// Returns `CliError` when the local Docker Engine connection cannot be initialized.
    pub fn new() -> Result<Self, CliError> {
        let docker = Docker::connect_with_local_defaults().map_err(|error| {
            CliErrorKind::command_failed("docker engine connect").with_details(error.to_string())
        })?;
        Ok(Self { docker })
    }

    pub fn daemon_reachable() -> bool {
        let Ok(docker) = Docker::connect_with_local_defaults() else {
            return false;
        };
        RUNTIME.block_on(docker.ping()).is_ok()
    }
}
